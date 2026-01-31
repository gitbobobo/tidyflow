use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    response::IntoResponse,
    routing::get,
    Router,
};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

use crate::pty::PtySession;
use crate::server::protocol::{ClientMessage, ServerMessage};

/// Run the WebSocket server on the specified port
pub async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    let app = Router::new().route("/ws", get(ws_handler));

    let addr = format!("127.0.0.1:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    info!("Listening on ws://{}/ws", addr);

    axum::serve(listener, app).await?;

    Ok(())
}

/// WebSocket upgrade handler
async fn ws_handler(ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(handle_socket)
}

/// Handle a WebSocket connection
async fn handle_socket(mut socket: WebSocket) {
    info!("New WebSocket connection established");

    // Create PTY session
    let session = match PtySession::new(None) {
        Ok(s) => s,
        Err(e) => {
            error!("Failed to create PTY session: {}", e);
            let _ = socket.close().await;
            return;
        }
    };

    let session_id = session.session_id().to_string();
    let shell_name = session.shell_name().to_string();

    info!(
        session_id = %session_id,
        shell = %shell_name,
        "PTY session created for WebSocket connection"
    );

    // Send Hello message
    let hello_msg = ServerMessage::Hello {
        version: 0,
        session_id: session_id.clone(),
        shell: shell_name.clone(),
    };

    if let Ok(json) = serde_json::to_string(&hello_msg) {
        if let Err(e) = socket.send(Message::Text(json)).await {
            error!("Failed to send Hello message: {}", e);
            return;
        }
    } else {
        error!("Failed to serialize Hello message");
        return;
    }

    // Wrap session in Arc<Mutex> for shared access
    let session = Arc::new(Mutex::new(session));

    // Create channels for communication
    let (tx_exit, mut rx_exit) = tokio::sync::mpsc::channel::<i32>(1);

    // Spawn PTY reader task
    let session_reader = Arc::clone(&session);
    let tx_exit_reader = tx_exit.clone();
    let (tx_output, mut rx_output) = tokio::sync::mpsc::channel::<Vec<u8>>(100);
    let session_id_reader = session_id.clone();

    tokio::spawn(async move {
        let mut buf = [0u8; 8192];
        loop {
            let bytes_read = {
                let mut sess = session_reader.lock().await;
                match sess.read_output(&mut buf) {
                    Ok(n) if n > 0 => n,
                    Ok(_) => {
                        debug!("PTY reader: EOF reached");
                        break;
                    }
                    Err(e) => {
                        error!("PTY reader error: {}", e);
                        break;
                    }
                }
            };

            if tx_output.send(buf[..bytes_read].to_vec()).await.is_err() {
                debug!("PTY reader: output channel closed");
                break;
            }

            // Check if child process has exited
            let exit_code = {
                let mut sess = session_reader.lock().await;
                sess.wait()
            };

            if let Some(code) = exit_code {
                info!(session_id = %session_id_reader, exit_code = code, "Child process exited");
                let _ = tx_exit_reader.send(code).await;
                break;
            }
        }
    });

    // Main loop: handle WebSocket messages and PTY output
    loop {
        tokio::select! {
            // Handle PTY output
            Some(output) = rx_output.recv() => {
                let data_b64 = BASE64.encode(&output);
                let msg = ServerMessage::Output { data_b64 };

                if let Ok(json) = serde_json::to_string(&msg) {
                    if let Err(e) = socket.send(Message::Text(json)).await {
                        error!("Failed to send output message: {}", e);
                        break;
                    }
                }
            }

            // Handle WebSocket messages
            Some(msg) = socket.recv() => {
                match msg {
                    Ok(Message::Text(text)) => {
                        match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(ClientMessage::Input { data_b64 }) => {
                                match BASE64.decode(&data_b64) {
                                    Ok(data) => {
                                        let mut sess = session.lock().await;
                                        if let Err(e) = sess.write_input(&data) {
                                            error!("Failed to write input to PTY: {}", e);
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        warn!("Failed to decode base64 input: {}", e);
                                    }
                                }
                            }
                            Ok(ClientMessage::Resize { cols, rows }) => {
                                let sess = session.lock().await;
                                if let Err(e) = sess.resize(cols, rows) {
                                    error!("Failed to resize PTY: {}", e);
                                }
                            }
                            Ok(ClientMessage::Ping) => {
                                let pong_msg = ServerMessage::Pong;
                                if let Ok(json) = serde_json::to_string(&pong_msg) {
                                    if let Err(e) = socket.send(Message::Text(json)).await {
                                        error!("Failed to send Pong message: {}", e);
                                        break;
                                    }
                                }
                            }
                            Err(e) => {
                                warn!("Failed to parse client message: {}", e);
                            }
                        }
                    }
                    Ok(Message::Close(_)) => {
                        info!("WebSocket connection closed by client");
                        break;
                    }
                    Ok(Message::Binary(_)) => {
                        warn!("Received unexpected binary message");
                    }
                    Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                        // Handled automatically by axum
                    }
                    Err(e) => {
                        error!("WebSocket error: {}", e);
                        break;
                    }
                }
            }

            // Handle process exit
            Some(exit_code) = rx_exit.recv() => {
                info!(session_id = %session_id, exit_code, "Sending exit message");
                let exit_msg = ServerMessage::Exit { code: exit_code };
                if let Ok(json) = serde_json::to_string(&exit_msg) {
                    let _ = socket.send(Message::Text(json)).await;
                }
                break;
            }

            else => {
                debug!("All channels closed, exiting");
                break;
            }
        }
    }

    // Clean up
    {
        let mut sess = session.lock().await;
        sess.kill();
    }

    info!(session_id = %session_id, "WebSocket connection handler finished");
}

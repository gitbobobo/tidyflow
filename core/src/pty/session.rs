use portable_pty::{Child, CommandBuilder, MasterPty, PtySize};
use std::io::{self, Read, Write};
use std::path::PathBuf;
use tracing::{debug, error, info, instrument, warn};
use uuid::Uuid;

use super::resize::resize_pty;

pub struct PtySession {
    session_id: String,
    master: Option<Box<dyn MasterPty + Send>>,
    child: Box<dyn Child + Send + Sync>,
    reader: Option<Box<dyn Read + Send>>,
    writer: Option<Box<dyn Write + Send>>,
    shell_name: String,
}

impl PtySession {
    #[instrument]
    pub fn new(cwd: Option<PathBuf>) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let session_id = Uuid::new_v4().to_string();
        info!(session_id = %session_id, "Creating new PTY session");

        // Try zsh first, fall back to bash
        let shell_path = if std::path::Path::new("/bin/zsh").exists() {
            "/bin/zsh"
        } else {
            "/bin/bash"
        };
        let shell_name = shell_path
            .split('/')
            .next_back()
            .unwrap_or("shell")
            .to_string();

        debug!(session_id = %session_id, shell = %shell_path, "Selected shell");

        // Create PTY system
        let pty_system = portable_pty::native_pty_system();

        // Create PTY with default size
        let size = PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        };

        let pair = pty_system.openpty(size)?;
        let master = pair.master;

        // Set working directory
        let working_dir =
            cwd.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")));

        debug!(session_id = %session_id, cwd = ?working_dir, "Setting working directory");

        // Build command
        let mut cmd = CommandBuilder::new(shell_path);
        cmd.cwd(working_dir);

        // Ensure term info is correct for rich terminal features
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("LANG", "en_US.UTF-8");

        // Spawn child process
        let child = pair.slave.spawn_command(cmd)?;

        // 关闭父进程中的 slave 端 FD，避免 master reader 永远收不到 EOF
        drop(pair.slave);

        info!(
            session_id = %session_id,
            shell = %shell_name,
            "PTY session created successfully"
        );

        // Get reader and writer
        let reader = master.try_clone_reader()?;
        let writer = master.take_writer()?;

        Ok(PtySession {
            session_id,
            master: Some(master),
            child,
            reader: Some(reader),
            writer: Some(writer),
            shell_name,
        })
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    pub fn shell_name(&self) -> &str {
        &self.shell_name
    }

    /// 从 session 中取出 reader，用于独立的读取线程
    pub fn take_reader(
        &mut self,
    ) -> Result<Box<dyn Read + Send>, Box<dyn std::error::Error + Send + Sync>> {
        // 优先取走 self.reader（避免多余的 FD 克隆），不足时再从 master 克隆
        if let Some(reader) = self.reader.take() {
            return Ok(reader);
        }
        self.master
            .as_ref()
            .ok_or_else(|| {
                Box::new(std::io::Error::other("PTY master already closed"))
                    as Box<dyn std::error::Error + Send + Sync>
            })?
            .try_clone_reader()
            .map_err(|e| {
                Box::new(std::io::Error::other(e.to_string()))
                    as Box<dyn std::error::Error + Send + Sync>
            })
    }

    #[instrument(skip(self, buf), fields(session_id = %self.session_id))]
    pub fn read_output(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let reader = self
            .reader
            .as_mut()
            .ok_or_else(|| io::Error::other("PTY reader already closed"))?;
        let bytes_read = reader.read(buf)?;
        debug!(
            session_id = %self.session_id,
            bytes = bytes_read,
            "Read output from PTY"
        );
        Ok(bytes_read)
    }

    #[instrument(skip(self, data), fields(session_id = %self.session_id, bytes = data.len()))]
    pub fn write_input(&mut self, data: &[u8]) -> io::Result<()> {
        let writer = self
            .writer
            .as_mut()
            .ok_or_else(|| io::Error::other("PTY writer already closed"))?;
        writer.write_all(data)?;
        writer.flush()?;
        debug!(
            session_id = %self.session_id,
            bytes = data.len(),
            "Wrote input to PTY"
        );
        Ok(())
    }

    #[instrument(skip(self), fields(session_id = %self.session_id, cols, rows))]
    pub fn resize(
        &self,
        cols: u16,
        rows: u16,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let master = self
            .master
            .as_ref()
            .ok_or_else(|| "PTY master already closed".to_string())?;
        resize_pty(master.as_ref(), cols, rows)?;
        info!(
            session_id = %self.session_id,
            cols,
            rows,
            "PTY session resized"
        );
        Ok(())
    }

    #[instrument(skip(self), fields(session_id = %self.session_id))]
    pub fn wait(&mut self) -> Option<i32> {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                let exit_code = status.exit_code() as i32;
                info!(
                    session_id = %self.session_id,
                    exit_code,
                    "Child process exited"
                );
                Some(exit_code)
            }
            Ok(None) => {
                debug!(session_id = %self.session_id, "Child process still running");
                None
            }
            Err(e) => {
                error!(
                    session_id = %self.session_id,
                    error = %e,
                    "Error checking child process status"
                );
                None
            }
        }
    }

    #[instrument(skip(self), fields(session_id = %self.session_id))]
    pub fn kill(&mut self) {
        info!(session_id = %self.session_id, "Killing PTY session");

        // 先释放 reader/writer/master FD，确保 PTY 资源不泄漏
        drop(self.reader.take());
        drop(self.writer.take());

        // Send SIGHUP to the child process
        if let Err(e) = self.child.kill() {
            warn!(
                session_id = %self.session_id,
                error = %e,
                "Error sending kill signal to child process"
            );
        }

        // Wait for the child to exit
        match self.child.wait() {
            Ok(status) => {
                info!(
                    session_id = %self.session_id,
                    exit_code = status.exit_code(),
                    "Child process terminated"
                );
            }
            Err(e) => {
                error!(
                    session_id = %self.session_id,
                    error = %e,
                    "Error waiting for child process to exit"
                );
            }
        }

        // 最后释放 master FD
        drop(self.master.take());
    }
}

impl Drop for PtySession {
    fn drop(&mut self) {
        debug!(session_id = %self.session_id, "Dropping PTY session");
        self.kill();
    }
}

use portable_pty::PtySize;
use tracing::{info, instrument};

#[instrument(skip(master), fields(cols, rows))]
pub fn resize_pty(
    master: &dyn portable_pty::MasterPty,
    cols: u16,
    rows: u16,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let size = PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    };
    master.resize(size)?;
    info!(cols, rows, "PTY resized");
    Ok(())
}

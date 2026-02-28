use super::http_client::OpenCodeError;
use std::collections::VecDeque;
use std::pin::Pin;
use std::task::{Context, Poll};

pub(crate) struct SseJsonStream {
    buffer: String,
    inner: Pin<
        Box<dyn tokio_stream::Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send + Unpin>,
    >,
    /// 已解析但尚未 yield 的事件队列。
    pending: VecDeque<Result<serde_json::Value, OpenCodeError>>,
}

impl SseJsonStream {
    pub(crate) fn new(
        bytes: impl tokio_stream::Stream<Item = Result<bytes::Bytes, reqwest::Error>>
            + Send
            + Unpin
            + 'static,
    ) -> Self {
        Self {
            buffer: String::new(),
            inner: Box::pin(bytes),
            pending: VecDeque::new(),
        }
    }

    /// 从 buffer 中提取完整的 SSE 事件（以空行分隔），解析 data 字段。
    fn parse_buffer(&mut self) {
        // SSE 事件以 "\n\n" 分隔。
        while let Some(pos) = self.buffer.find("\n\n") {
            let event_block = self.buffer[..pos].to_string();
            self.buffer = self.buffer[pos + 2..].to_string();

            // SSE 规范允许多行 data，这里按换行拼接。
            let mut data = String::new();
            for line in event_block.lines() {
                if let Some(d) = line.strip_prefix("data:") {
                    if !data.is_empty() {
                        data.push('\n');
                    }
                    data.push_str(d.trim_start());
                }
            }

            if data.is_empty() {
                continue;
            }

            match serde_json::from_str::<serde_json::Value>(&data) {
                Ok(event) => self.pending.push_back(Ok(event)),
                Err(e) => {
                    self.pending.push_back(Err(OpenCodeError::SseError(format!(
                        "Failed to parse SSE event: {} (data: {})",
                        e,
                        &data[..data.len().min(200)]
                    ))));
                }
            }
        }
    }
}

impl tokio_stream::Stream for SseJsonStream {
    type Item = Result<serde_json::Value, OpenCodeError>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();

        // 优先返回已解析好的事件。
        if let Some(event) = this.pending.pop_front() {
            return Poll::Ready(Some(event));
        }

        match Pin::new(&mut this.inner).poll_next(cx) {
            Poll::Ready(Some(Ok(bytes))) => {
                if let Ok(text) = std::str::from_utf8(&bytes) {
                    this.buffer.push_str(text);
                }
                this.parse_buffer();

                if let Some(event) = this.pending.pop_front() {
                    Poll::Ready(Some(event))
                } else {
                    // 数据不完整，继续等下一段字节流。
                    cx.waker().wake_by_ref();
                    Poll::Pending
                }
            }
            Poll::Ready(Some(Err(e))) => Poll::Ready(Some(Err(OpenCodeError::HttpError(e)))),
            Poll::Ready(None) => {
                // 流结束后，尝试冲刷 buffer 剩余内容。
                if !this.buffer.trim().is_empty() {
                    this.buffer.push_str("\n\n");
                    this.parse_buffer();
                }
                if let Some(event) = this.pending.pop_front() {
                    Poll::Ready(Some(event))
                } else {
                    Poll::Ready(None)
                }
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

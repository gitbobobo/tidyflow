// handlers module - Protocol message handlers
// Contains handlers for workspace, terminal, git, file operations

pub mod ai;
pub mod evolution;
pub mod evolution_prompts;
pub mod file;
pub mod git;
pub mod log;
pub mod project;
pub mod settings;
pub mod terminal;

macro_rules! dispatch_handlers {
    ($($call:expr),+ $(,)?) => {{
        $(
            if $call.await? {
                return Ok(true);
            }
        )+
    }};
}

pub(crate) use dispatch_handlers;

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    async fn push_and_return(
        trace: Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
        value: bool,
    ) -> Result<bool, String> {
        trace.lock().expect("lock trace").push(label);
        Ok(value)
    }

    async fn run_dispatch(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "first", false),
            push_and_return(trace.clone(), "second", true),
            push_and_return(trace.clone(), "third", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn dispatch_handlers_short_circuits_in_order() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = run_dispatch(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(*trace.lock().expect("lock trace"), vec!["first", "second"]);
    }
}

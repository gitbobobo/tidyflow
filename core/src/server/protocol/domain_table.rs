//! 自动生成文件，请勿手改。
//!
//! 来源：`schema/protocol/v6/domains.yaml`
//! 生成命令：`./scripts/tools/gen_protocol_domain_table.sh`

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum DomainRoute {
    System,
    Terminal,
    File,
    Git,
    Project,
    Settings,
    Log,
    Ai,
    Evolution,
}

pub const DOMAIN_IDS: &[&str] = &[
    "system",
    "terminal",
    "file",
    "git",
    "project",
    "settings",
    "log",
    "ai",
    "evolution",
];

pub fn parse_domain_route(domain: &str) -> Option<DomainRoute> {
    match domain {
        "system" => Some(DomainRoute::System),
        "terminal" => Some(DomainRoute::Terminal),
        "file" => Some(DomainRoute::File),
        "git" => Some(DomainRoute::Git),
        "project" => Some(DomainRoute::Project),
        "settings" => Some(DomainRoute::Settings),
        "log" => Some(DomainRoute::Log),
        "ai" => Some(DomainRoute::Ai),
        "evolution" => Some(DomainRoute::Evolution),
        _ => None,
    }
}

pub fn domain_route_id(route: DomainRoute) -> &'static str {
    match route {
        DomainRoute::System => "system",
        DomainRoute::Terminal => "terminal",
        DomainRoute::File => "file",
        DomainRoute::Git => "git",
        DomainRoute::Project => "project",
        DomainRoute::Settings => "settings",
        DomainRoute::Log => "log",
        DomainRoute::Ai => "ai",
        DomainRoute::Evolution => "evolution",
    }
}

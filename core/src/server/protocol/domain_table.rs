//! 自动生成文件，请勿手改。
//!
//! 来源：`schema/protocol/v10/domains.yaml`
//! 生成命令：`./scripts/tools/gen_protocol_domain_table.sh`

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum DomainRoute {
    System,
    Terminal,
    File,
    Git,
    Project,
    Settings,
    Ai,
    Evidence,
    Evolution,
    Health,
    Node,
}

pub const DOMAIN_IDS: &[&str] = &[
    "system",
    "terminal",
    "file",
    "git",
    "project",
    "settings",
    "ai",
    "evidence",
    "evolution",
    "health",
    "node",
];

pub fn parse_domain_route(domain: &str) -> Option<DomainRoute> {
    match domain {
        "system" => Some(DomainRoute::System),
        "terminal" => Some(DomainRoute::Terminal),
        "file" => Some(DomainRoute::File),
        "git" => Some(DomainRoute::Git),
        "project" => Some(DomainRoute::Project),
        "settings" => Some(DomainRoute::Settings),
        "ai" => Some(DomainRoute::Ai),
        "evidence" => Some(DomainRoute::Evidence),
        "evolution" => Some(DomainRoute::Evolution),
        "health" => Some(DomainRoute::Health),
        "node" => Some(DomainRoute::Node),
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
        DomainRoute::Ai => "ai",
        DomainRoute::Evidence => "evidence",
        DomainRoute::Evolution => "evolution",
        DomainRoute::Health => "health",
        DomainRoute::Node => "node",
    }
}

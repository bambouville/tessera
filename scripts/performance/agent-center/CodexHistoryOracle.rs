//! Test-only bridge to actual upstream code; never bundled with Tessera.
use codex_app_server_protocol::{ThreadHistoryBuilder, ThreadItem};
use codex_protocol::items::TurnItem;
use codex_protocol::protocol::RolloutItem;
use std::io::{self, BufRead, Read, Write};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = io::BufReader::new(io::stdin().lock());
    let mut output = io::BufWriter::new(io::stdout().lock());
    let mut history = ThreadHistoryBuilder::new();
    loop {
        let mut header = String::new();
        if input.read_line(&mut header)? == 0 { break; }
        let length: usize = header.trim().parse()?;
        if length == 0 || length > 4 * 1024 * 1024 { return Err("oracle frame budget".into()); }
        let mut bytes = vec![0; length];
        input.read_exact(&mut bytes)?;
        let request: serde_json::Value = serde_json::from_slice(&bytes)?;
        let result = match request.get("operation").and_then(|value| value.as_str()) {
            Some("core") => match serde_json::from_value::<TurnItem>(request["item"].clone()) {
                Ok(item) => serde_json::json!({"item": ThreadItem::from(item)}),
                Err(_) => serde_json::json!({"error":"upstreamCoreShape"}),
            },
            Some("legacy") => match serde_json::from_value::<RolloutItem>(request["item"].clone()) {
                Ok(item) => {
                    let changes = history.handle_rollout_item_with_changes(&item);
                    let items: Vec<_> = changes.changed_items.into_iter().map(|change| serde_json::json!({
                        "turn": change.turn_id, "item": change.item,
                        "startedAt": change.started_at_ms, "completedAt": change.completed_at_ms,
                    })).collect();
                    let turns: Vec<_> = changes.changed_turns.into_iter().map(|change| serde_json::json!({
                        "turn": change.turn_id, "status": change.status, "error": change.error,
                        "startedAt": change.started_at, "completedAt": change.completed_at, "durationMs": change.duration_ms,
                    })).collect();
                    serde_json::json!({"items": items, "turns": turns, "removedTurns": changes.removed_turn_ids})
                }
                Err(_) => serde_json::json!({"error":"upstreamRolloutShape"}),
            },
            Some("reset") => { history.reset(); serde_json::json!({"reset":true}) }
            _ => serde_json::json!({"error":"oracleOperation"}),
        };
        serde_json::to_writer(&mut output, &result)?;
        output.write_all(b"\n")?;
        output.flush()?;
    }
    Ok(())
}

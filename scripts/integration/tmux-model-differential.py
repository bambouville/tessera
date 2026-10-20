#!/usr/bin/env python3
"""Local half of the tmux semantics model differential lane.

The scenario scripts in
Packages/TmuxControl/Tests/TmuxSemanticsModelTests/Scenarios/ drive both the
Swift model (TmuxSemanticsModel) and real tmux on a disposable VPS fixture
(remote/tmux-model-runner.py). This helper never connects anywhere:

  validate SCENARIO...                  parse the scripts (same grammar and
                                        step numbering as Scenario.swift)
  prepare --out DIR SCENARIO...         write DIR/plan.json and DIR/payload.py,
                                        the runner with the plan embedded
  diff --plan P --real R --model M      compare what real tmux sent each
                                        control client with the model's replay
                                        of the same timeline; exit 1 on any
                                        difference
  synthesize --plan P --nominal DIR     host-free check of replay and diff:
      --variant same|mutated|shifted    writes runner-shaped output built from
      --out FILE                        the model's nominal transcripts, with
                                        real-looking client names, guard times
                                        and numbers, and pane output; `mutated`
                                        changes one line, `shifted` moves one
                                        line into the next step

run-tmux-model-differential.sh drives the whole lane.
"""
import argparse
import base64
import difflib
import json
import os
import re
import sys

VERSIONS = ["3.2", "3.3a", "3.4", "3.6a"]
SETUP = {"session", "window", "group"}
ACTIONS = {"control", "tty", "send", "key", "resize", "detach", "advance"}
EXPECTS = {"expect", "expect-not", "expect-size", "expect-latest", "expect-current"}
RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote", "tmux-model-runner.py")
PLACEHOLDER = "__PLAN_BASE64__"
# Control-mode lines that carry pane content, not server semantics.
DROPPED_PREFIXES = ("%output ", "%extended-output ")
GUARD = re.compile(r"^(%begin|%end|%error) \d+ \d+ (\d+)$")
ID_TOKEN = re.compile(r"(?<![\w$@%])([$@%]\d+)(?!\w)")


class ScenarioError(Exception):
    def __init__(self, path, line, message):
        super().__init__(f"{path}:{line}: {message}")


def parse_size(text, fail):
    match = re.fullmatch(r"(\d+)x(\d+)", text)
    if not match or int(match.group(1)) == 0 or int(match.group(2)) == 0:
        raise fail(f"bad size {text} (want WxH)")
    return [int(match.group(1)), int(match.group(2))]


def parse_scenario(path):
    """Mirrors ScenarioScript.parse: one step per directive after the
    `scenario`/`versions` header, numbered from 0."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    name, versions, steps = None, list(VERSIONS), []
    sessions, windows, clients, detached = set(), set(), {}, set()
    saw_client = False
    for number, raw in enumerate(text.split("\n"), 1):
        line = raw.strip(" \t")
        if not line or line.startswith("#"):
            continue
        keyword, _, rest = line.partition(" ")
        rest = rest.strip(" \t")
        words = rest.split()

        def fail(message, number=number):
            return ScenarioError(path, number, message)

        def count(n):
            if len(words) != n:
                raise fail(f"{keyword} takes {n} arguments")

        def known(client, control=None):
            if client not in clients:
                raise fail(f"unknown client {client}")
            if client in detached:
                raise fail(f"client {client} has detached")
            if control is not None and clients[client] != control:
                raise fail(f"{client} is {'a control' if clients[client] else 'a terminal'} client")

        if name is None:
            if keyword != "scenario" or len(words) != 1:
                raise fail("the first directive must be `scenario NAME`")
            name = words[0]
            continue
        if keyword == "versions":
            if steps:
                raise fail("`versions` must precede the steps")
            for word in words:
                if word not in VERSIONS:
                    raise fail(f"unknown version {word}")
            if not words:
                raise fail("`versions` needs at least one version")
            versions = words
            continue
        step = {"index": len(steps), "line": number, "kind": keyword}
        if keyword == "session":
            count(3)
            if words[0] in sessions or words[2] in windows or words[2] in sessions or words[0] == words[2]:
                raise fail("duplicate name")
            step.update(name=words[0], size=parse_size(words[1], fail), window=words[2])
            sessions.add(words[0])
            windows.add(words[2])
        elif keyword == "window":
            count(2)
            if words[0] not in sessions:
                raise fail(f"unknown session {words[0]}")
            if words[1] in windows or words[1] in sessions:
                raise fail(f"duplicate name {words[1]}")
            windows.add(words[1])
            step.update(session=words[0], label=words[1])
        elif keyword == "group":
            count(2)
            if words[1] not in sessions:
                raise fail(f"unknown session {words[1]}")
            if words[0] in sessions or words[0] in windows:
                raise fail(f"duplicate name {words[0]}")
            sessions.add(words[0])
            step.update(name=words[0], target=words[1])
        elif keyword in ("control", "tty"):
            control = keyword == "control"
            sizes = 0 if control else 1
            if len(words) not in (2 + sizes, 3 + sizes):
                raise fail("control CLIENT SESSION [FLAGS]" if control else "tty CLIENT SESSION WxH [FLAGS]")
            if words[1] not in sessions:
                raise fail(f"unknown session {words[1]}")
            if words[0] in clients:
                raise fail(f"duplicate client {words[0]}")
            clients[words[0]] = control
            flags = words[2 + sizes].split(",") if len(words) == 3 + sizes else []
            step.update(client=words[0], session=words[1], flags=flags)
            if not control:
                step["size"] = parse_size(words[2], fail)
        elif keyword == "send":
            if not words:
                raise fail("send CLIENT LINE")
            known(words[0], control=True)
            command = rest[len(words[0]):].strip(" \t")
            if not command:
                raise fail("send needs a command line")
            step.update(client=words[0], command=command)
        elif keyword in ("key", "detach"):
            count(1)
            known(words[0], control=False if keyword == "key" else None)
            if keyword == "detach":
                detached.add(words[0])
            step.update(client=words[0])
        elif keyword == "resize":
            count(2)
            known(words[0], control=False)
            step.update(client=words[0], size=parse_size(words[1], fail))
        elif keyword == "advance":
            count(1)
            try:
                seconds = float(words[0])
            except ValueError:
                seconds = -1
            if not 0 < seconds <= 30:
                raise fail("advance takes 0 < SECONDS <= 30")
            step.update(seconds=seconds)
        elif keyword in EXPECTS:
            if keyword in ("expect", "expect-not") and (not words or clients.get(words[0]) is not True):
                raise fail(f"{keyword} needs a control client")
        else:
            raise fail(f"unknown directive {keyword}")
        if keyword in SETUP and saw_client:
            raise fail("setup must come before the first client")
        if keyword in ("control", "tty"):
            saw_client = True
        steps.append(step)
    if name is None:
        raise ScenarioError(path, 0, "empty scenario")
    if not any(step["kind"] in ACTIONS for step in steps):
        raise ScenarioError(path, 0, "no action steps")
    if name != os.path.splitext(os.path.basename(path))[0]:
        raise ScenarioError(path, 0, f"scenario {name} must live in {name}.scenario")
    return {
        "name": name,
        "versions": versions,
        "source": text,
        "setup": [step for step in steps if step["kind"] in SETUP],
        "actions": [step for step in steps if step["kind"] in ACTIONS],
    }


def command_validate(args):
    scenarios = [parse_scenario(path) for path in args.scenarios]
    for scenario in scenarios:
        print(f"{scenario['name']}: {len(scenario['setup'])} setup, {len(scenario['actions'])} actions, "
              f"versions {' '.join(scenario['versions'])}")
    names = [scenario["name"] for scenario in scenarios]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise SystemExit(f"duplicate scenarios: {', '.join(duplicates)}")
    if not scenarios:
        raise SystemExit("no scenarios")


def command_prepare(args):
    if not re.fullmatch(r"[A-Za-z0-9-]{1,40}", args.run_id):
        raise SystemExit("--run-id must be 1-40 letters, digits or dashes")
    if not 0.05 <= args.settle <= 5:
        raise SystemExit("--settle must be within 0.05...5 seconds")
    scenarios = [parse_scenario(path) for path in args.scenarios]
    if not scenarios:
        raise SystemExit("no scenarios")
    plan = {"format": 1, "run_id": args.run_id, "settle": args.settle, "scenarios": scenarios}
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "plan.json"), "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=2, sort_keys=True)
    with open(RUNNER, encoding="utf-8") as handle:
        runner = handle.read()
    if runner.count(PLACEHOLDER) != 1:
        raise SystemExit(f"{RUNNER} must contain {PLACEHOLDER} exactly once")
    encoded = base64.b64encode(json.dumps(plan, sort_keys=True).encode()).decode()
    with open(os.path.join(args.out, "payload.py"), "w", encoding="utf-8") as handle:
        handle.write(runner.replace(PLACEHOLDER, encoded))
    actions = sum(len(scenario["actions"]) for scenario in scenarios)
    print(f"prepared {len(scenarios)} scenarios, {actions} actions, settle {args.settle}s, run {args.run_id}")


# --- diff -----------------------------------------------------------------


def normalize(lines, names):
    """Drops pane output, strips guard times and numbers (`%begin 1`), and
    replaces real client names (`client-PID`, `/dev/pts/N`) with labels."""
    renames = sorted(names.items(), key=lambda item: -len(item[1]))
    result = []
    for line in lines:
        if line.startswith(DROPPED_PREFIXES):
            continue
        guard = GUARD.match(line)
        if guard:
            line = f"{guard.group(1)} {guard.group(2)}"
        for label, real in renames:
            if real:
                line = re.sub(r"(?<![\w/-])" + re.escape(real) + r"(?![\w/-])", label, line)
        result.append(line)
    return result


def relabel(lines, ids):
    """Replaces `$N`, `@N` and `%N` tokens with `{NAME}`."""
    names = {value: key for key, value in ids.items()}
    return [ID_TOKEN.sub(lambda match: "{" + names[match.group(1)] + "}" if match.group(1) in names else match.group(1), line)
            for line in lines]


def diff_scenario(plan_scenario, real, model, settle):
    """Returns (differences, notes) for one scenario."""
    differences, notes = [], []
    if real.get("status") != "ok":
        return [f"real run failed: {real.get('status')}"], notes
    if model.get("unsupported"):
        return [f"model input unsupported (the run proves nothing): {model['unsupported']}"], notes
    names = real.get("clients", {})
    real_ids, model_ids = real.get("ids", {}), model.get("ids", {})
    relabelled = real_ids != model_ids
    if relabelled:
        differences.append(f"id assignment differs: real {real_ids} model {model_ids}")
    kinds = {step["index"]: step for step in plan_scenario["actions"]}
    real_steps = {step["index"]: step for step in real.get("steps", [])}
    model_steps = {step["index"]: step for step in model.get("steps", [])}
    if sorted(real_steps) != sorted(model_steps):
        differences.append(f"step sets differ: real {sorted(real_steps)} model {sorted(model_steps)}")
    labels = sorted({label for step in real_steps.values() for label in step.get("lines", {})}
                    | {label for step in model_steps.values() for label in step.get("lines", {})})

    def lines(step, label, ids, rename):
        raw = (step or {}).get("lines", {}).get(label, [])
        text = normalize(raw, rename)
        return relabel(text, ids) if relabelled else text

    for label in labels:
        real_stream, model_stream, step_diffs = [], [], []
        for index in sorted(set(real_steps) | set(model_steps)):
            got = lines(real_steps.get(index), label, real_ids, names)
            want = lines(model_steps.get(index), label, model_ids, {})
            real_stream += got
            model_stream += want
            if got != want:
                step = kinds.get(index, {})
                what = " ".join(str(part) for part in (step.get("kind"), step.get("client"), step.get("command")) if part)
                title = f"step {index} (line {step.get('line')}: {what})"
                step_diffs.append((index, title, got, want))
        if real_stream != model_stream:
            body = "\n".join(difflib.unified_diff(model_stream, real_stream, f"model/{label}", f"real/{label}", lineterm="", n=2))
            differences.append(f"{label}: control stream differs\n{body}")
            for index, title, got, want in step_diffs:
                body = "\n".join(difflib.unified_diff(want, got, "model", "real", lineterm="", n=1))
                differences.append(f"{label}: {title}\n{body}")
        elif step_diffs:
            moved = ", ".join(str(index) for index, *_ in step_diffs)
            notes.append(f"{label}: same stream, but lines crossed step boundaries at steps {moved} "
                         f"(output later than the {settle}s settle; rerun with a longer TESSERA_TMUX_MODEL_SETTLE)")
    for step in real.get("steps", []):
        late = step.get("read", 0) - step.get("start", 0) - kinds.get(step["index"], {}).get("seconds", 0)
        if late > settle * 3:
            notes.append(f"step {step['index']} was read {late:.2f}s after its action (settle {settle}s)")
    return differences, notes


def command_diff(args):
    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    with open(args.real, encoding="utf-8") as handle:
        real = json.load(handle)
    with open(args.model, encoding="utf-8") as handle:
        model = json.load(handle)
    by_name = {scenario["name"]: scenario for scenario in plan["scenarios"]}
    report, summary, failed = [], [], False
    real_runs, model_runs = real.get("runs", []), model.get("runs", [])
    if not real_runs:
        failed = True
        report.append("real result has no runs")
    for run in real_runs:
        twins = [m for m in model_runs if m.get("tmux") == run.get("tmux") and m.get("version") == run.get("version")]
        header = f"== {run.get('version')} ({run.get('tmux')})"
        if len(twins) != 1:
            failed = True
            report.append(f"{header}: no model replay")
            summary.append({"tmux": run.get("tmux"), "version": run.get("version"), "status": "no model replay"})
            continue
        twin = twins[0]
        mapping = twin["modelVersion"] + ("" if twin.get("exact") else " (unverified mapping)")
        report.append(f"{header} -> model {mapping}")
        model_scenarios = {scenario["scenario"]: scenario for scenario in twin.get("scenarios", [])}
        for scenario in run.get("scenarios", []):
            name = scenario.get("name")
            declared = twin["modelVersion"] in by_name.get(name, {}).get("versions", [])
            if name not in by_name:
                differences, notes = [f"scenario {name} is not in the plan"], []
            elif scenario.get("status") == "ok" and name not in model_scenarios:
                differences, notes = ["no model replay for this scenario"], []
            else:
                differences, notes = diff_scenario(by_name[name], scenario, model_scenarios.get(name, {}), plan["settle"])
            if declared:
                notes += [f"model expectation at real timing: {failure}" for failure in model_scenarios.get(name, {}).get("failures", [])]
            status = "different" if differences else "same"
            failed = failed or bool(differences)
            report.append(f"-- {name}: {status}{'' if declared else ' (version not declared by the scenario)'}")
            report += ["   " + line for difference in differences for line in difference.split("\n")]
            report += [f"   note: {note}" for note in notes]
            summary.append({"tmux": run.get("tmux"), "version": run.get("version"), "model": twin["modelVersion"],
                            "exact": twin.get("exact"), "scenario": name, "status": status,
                            "differences": differences, "notes": notes})
        missing = sorted(set(by_name) - {scenario.get("name") for scenario in run.get("scenarios", [])})
        if missing:
            failed = True
            report.append(f"-- missing from the real run: {', '.join(missing)}")
    text = "\n".join(report) + "\n"
    with open(args.report, "w", encoding="utf-8") as handle:
        handle.write(text)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"different": failed, "results": summary}, handle, indent=2)
    sys.stdout.write(text)
    if failed:
        raise SystemExit(1)


def command_synthesize(args):
    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    runs, mutated, shifted = [], False, False
    for version in VERSIONS:
        run = {"tmux": "synthetic", "version": f"tmux {version}", "scenarios": []}
        for scenario in plan["scenarios"]:
            path = os.path.join(args.nominal, f"{scenario['name']}--{version}.json")
            with open(path, encoding="utf-8") as handle:
                nominal = json.load(handle)
            clients, pts = {}, 0
            for step in scenario["actions"]:
                if step["kind"] == "control":
                    clients[step["client"]] = f"client-{31000 + len(clients)}"
                elif step["kind"] == "tty":
                    pts += 1
                    clients[step["client"]] = f"/dev/pts/{pts}"
            renames = sorted(clients.items(), key=lambda item: -len(item[0]))
            steps = []
            for number, step in enumerate(nominal["steps"]):
                lines = {}
                for label, raw in step["lines"].items():
                    out = [f"%output {nominal['ids'].get('pane:' + scenario['setup'][0].get('window', ''), '%0')} x"]
                    for line in raw:
                        guard = re.match(r"^(%begin|%end|%error) (\d+) (\d+) (\d+)$", line)
                        if guard:
                            line = f"{guard.group(1)} {int(guard.group(2)) + 86400} {int(guard.group(3)) + 500} {guard.group(4)}"
                        for name, real in renames:
                            line = re.sub(r"(?<![\w/-])" + re.escape(name) + r"(?![\w/-])", real, line)
                        out.append(line)
                    lines[label] = out
                steps.append({"index": step["index"], "kind": "synthetic", "start": step["start"],
                              "read": step["read"], "lines": lines})
            if args.variant == "mutated" and not mutated:
                for step in steps:
                    for label, lines in step["lines"].items():
                        for i, line in enumerate(lines):
                            if line.startswith("%layout-change ") and not mutated:
                                lines[i] = line + " mutated"
                                mutated = True
            if args.variant == "shifted" and not shifted:
                for earlier, later in zip(steps, steps[1:]):
                    for label, lines in earlier["lines"].items():
                        if not shifted and label in later["lines"] and len(lines) > 1:
                            later["lines"][label].insert(0, lines.pop())
                            shifted = True
            run["scenarios"].append({"name": scenario["name"], "source": scenario["source"], "status": "ok",
                                     "ids": nominal["ids"], "clients": clients, "steps": steps,
                                     "stderr": {}, "cleanup": "verified"})
        runs.append(run)
    if args.variant == "mutated" and not mutated:
        raise SystemExit("no %layout-change line to mutate")
    if args.variant == "shifted" and not shifted:
        raise SystemExit("no line to shift")
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump({"format": 1, "run_id": plan["run_id"], "host": "synthetic", "runs": runs}, handle, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("scenarios", nargs="+")
    validate.set_defaults(run=command_validate)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--out", required=True)
    prepare.add_argument("--run-id", required=True)
    prepare.add_argument("--settle", type=float, default=0.3)
    prepare.add_argument("scenarios", nargs="+")
    prepare.set_defaults(run=command_prepare)
    diff = commands.add_parser("diff")
    diff.add_argument("--plan", required=True)
    diff.add_argument("--real", required=True)
    diff.add_argument("--model", required=True)
    diff.add_argument("--report", required=True)
    diff.add_argument("--json")
    diff.set_defaults(run=command_diff)
    synthesize = commands.add_parser("synthesize")
    synthesize.add_argument("--plan", required=True)
    synthesize.add_argument("--nominal", required=True)
    synthesize.add_argument("--variant", choices=["same", "mutated", "shifted"], required=True)
    synthesize.add_argument("--out", required=True)
    synthesize.set_defaults(run=command_synthesize)
    args = parser.parse_args()
    try:
        args.run(args)
    except ScenarioError as error:
        raise SystemExit(f"error: {error}")


if __name__ == "__main__":
    main()

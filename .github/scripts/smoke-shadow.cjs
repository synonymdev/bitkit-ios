"use strict";

const { execFileSync } = require("node:child_process");

const CODE =
  /^(Bitkit\/|BitkitNotification\/|BitkitWidget\/|Bitkit\.xcodeproj\/|Package\.swift$|\.github\/scripts\/|\.github\/actions\/swift-packages\/|\.github\/workflows\/e2e-smoke-shadow\.yml$|scripts\/)/;

function eligible(eventName, event) {
  if (eventName === "workflow_dispatch") return true;
  const pr = event.pull_request;
  return (
    eventName === "pull_request" &&
    pr &&
    !pr.draft &&
    pr.base.ref === "master" &&
    (event.action !== "edited" || Boolean(event.changes?.base))
  );
}

function needsSmoke(eventName, event, files) {
  return Boolean(
    eligible(eventName, event) &&
      (eventName === "workflow_dispatch" ||
        files.some((file) => CODE.test(file))),
  );
}

function verifyMerge({ tested, parents, head, base }) {
  if (
    ![tested, head, base].every((sha) => /^[0-9a-f]{40}$/.test(sha)) ||
    parents.length !== 2 ||
    parents[0] !== base ||
    parents[1] !== head
  ) {
    throw new Error("Shadow checkout is not the current PR merge candidate");
  }
}

async function inspect(
  { github, context },
  git = (args) => execFileSync("git", args, { encoding: "utf8" }).trim(),
) {
  if (!eligible(context.eventName, context.payload))
    return { code: false, reason: "draft or unrelated event" };
  const tested = git(["rev-parse", "HEAD"]);
  if (context.eventName === "workflow_dispatch") {
    if (tested !== context.sha)
      throw new Error(
        "Manual shadow checkout does not match its dispatched revision",
      );
    return {
      code: true,
      tested,
      head: tested,
      base: tested,
      reason: "manual dispatch",
    };
  }
  const number = context.payload.pull_request.number;
  const [{ data: pr }, { data: baseRef }] = await Promise.all([
    github.rest.pulls.get({ ...context.repo, pull_number: number }),
    github.rest.git.getRef({ ...context.repo, ref: "heads/master" }),
  ]);
  if (pr.draft || pr.base.ref !== "master")
    throw new Error("PR eligibility changed after the shadow event");
  const head = pr.head.sha,
    base = baseRef.object.sha;
  if (head !== context.payload.pull_request.head.sha)
    throw new Error("PR head changed after the shadow event");
  verifyMerge({
    tested,
    head,
    base,
    parents: git(["show", "-s", "--format=%P", tested]).split(" "),
  });
  const files = git(["diff", "--name-only", "-z", base, tested])
    .split("\0")
    .filter(Boolean);
  return {
    code: needsSmoke(context.eventName, context.payload, files),
    tested,
    head,
    base,
    reason: "verified PR merge",
  };
}

function verdict(detection, code, smoke) {
  if (detection !== "success")
    return { pass: false, message: "Shadow change detection did not succeed." };
  if (code === "false")
    return {
      pass: true,
      message:
        "Shadow smoke not required: successful detection found no applicable code changes.",
    };
  if (code !== "true")
    return {
      pass: false,
      message: "Shadow change selection is missing or invalid.",
    };
  return {
    pass: smoke === "success",
    message:
      smoke === "success"
        ? "Shadow smoke passed all expected cases."
        : `Shadow smoke incomplete: build/setup/test job ${smoke}.`,
  };
}

module.exports = { eligible, needsSmoke, verifyMerge, inspect, verdict };

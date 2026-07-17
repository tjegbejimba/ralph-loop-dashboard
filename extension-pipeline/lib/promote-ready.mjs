import { promoteOneTapReadiness } from "../../extension/lib/lane-promotion.mjs";

function linkedPrRepo(pr, fallbackRepo) {
  try {
    const url = new URL(String(pr?.url || ""));
    const match = url.hostname === "github.com" ? url.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/\d+\/?$/) : null;
    return match ? `${match[1]}/${match[2]}` : fallbackRepo;
  } catch {
    return fallbackRepo;
  }
}

export async function fetchPromotionIssue({ repoSlug, issueNumber, ghJson }) {
  const issue = await ghJson([
    "issue",
    "view",
    String(issueNumber),
    "--repo",
    repoSlug,
    "--json",
    "number,title,body,labels,state,assignees,closedByPullRequestsReferences",
  ]);
  const linkedPrs = Array.isArray(issue?.closedByPullRequestsReferences)
    ? issue.closedByPullRequestsReferences
    : [];
  issue.closedByPullRequestsReferences = await Promise.all(
    linkedPrs.map((pr) =>
      ghJson([
        "pr",
        "view",
        String(pr.number),
        "--repo",
        linkedPrRepo(pr, repoSlug),
        "--json",
        "number,state,url",
      ]),
    ),
  );
  return issue;
}

export async function handlePromoteReadyRequest({
  method,
  url,
  repos,
  expectedToken,
  requestToken,
  promote,
}) {
  if (method !== "POST") {
    return { status: 405, body: { error: "Method not allowed" } };
  }
  if (!expectedToken || requestToken !== expectedToken) {
    return { status: 403, body: { error: "Invalid promotion token" } };
  }

  const repoSlug = url.searchParams.get("repo") || "";
  if (!repos.some((repo) => repo.slug === repoSlug)) {
    return { status: 404, body: { error: "Unknown repository" } };
  }

  const issueNumber = Number(url.searchParams.get("issue"));
  if (!Number.isInteger(issueNumber) || issueNumber < 1) {
    return { status: 400, body: { error: "issue must be a positive integer" } };
  }

  const body = await promote({ repoSlug, issueNumber });
  return { status: body.promoted ? 200 : 409, body };
}

export async function promoteReadyFromPipeline({
  repoSlug,
  issueNumber,
  fetchIssue,
  editIssue,
}) {
  if (!repoSlug || typeof repoSlug !== "string") throw new TypeError("repoSlug is required");
  if (!Number.isInteger(issueNumber) || issueNumber < 1) {
    throw new TypeError("issueNumber must be a positive integer");
  }
  if (typeof fetchIssue !== "function") throw new TypeError("fetchIssue is required");
  if (typeof editIssue !== "function") throw new TypeError("editIssue is required");

  const issue = await fetchIssue({ repoSlug, issueNumber });
  if (!issue) {
    return {
      promoted: false,
      issueNumber,
      labelsAdded: [],
      labelsRemoved: [],
      skipReason: "Issue not found",
    };
  }

  const result = promoteOneTapReadiness({ issue, live: true });
  if (!result.promoted) return result;

  await editIssue({
    repoSlug,
    issueNumber,
    labelsAdded: result.labelsAdded,
    labelsRemoved: result.labelsRemoved,
  });
  return result;
}

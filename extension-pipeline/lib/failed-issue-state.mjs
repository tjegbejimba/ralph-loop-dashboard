export async function fetchMissingFailedIssueStates({
  repoSlug,
  failedRunItems = [],
  knownIssues = [],
  fetchIssue,
}) {
  if (!repoSlug || typeof repoSlug !== "string") {
    throw new TypeError("repoSlug is required");
  }
  if (typeof fetchIssue !== "function") {
    throw new TypeError("fetchIssue is required");
  }

  const knownNumbers = new Set(knownIssues.map((issue) => Number(issue?.number)));
  const missingNumbers = [
    ...new Set(
      failedRunItems
        .map((item) => Number(item?.number))
        .filter((number) => Number.isInteger(number) && number > 0 && !knownNumbers.has(number)),
    ),
  ];
  const settled = await Promise.allSettled(
    missingNumbers.map((issueNumber) => fetchIssue({ repoSlug, issueNumber })),
  );
  const issues = [];
  const errors = [];

  settled.forEach((result, index) => {
    if (result.status === "fulfilled") {
      if (result.value) issues.push(result.value);
      return;
    }
    errors.push({
      issueNumber: missingNumbers[index],
      message: String(result.reason?.message || result.reason),
    });
  });

  return { issues, errors };
}

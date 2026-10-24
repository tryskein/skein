# Security policy

## Reporting a vulnerability

**Do not open a public issue.** A public report tells everyone about the hole,
including people who will use it, while it is still unfixed.

Report it privately through GitHub's private vulnerability reporting: open the
**Security** tab of the affected repository and choose **Report a
vulnerability**. If that is not possible for you, email info@sebocorp.com.

If you are unsure whether what you found counts, report it anyway. Deciding
that is our job, not yours.

## What to include

Enough for us to reproduce it. In practice:

- what version, and how it is deployed (docker compose, Kubernetes, other);
- what you did, step by step;
- what you got that you should not have — the concrete result, not a
  description of the risk;
- how you found it, if that is not obvious.

Please test only against your own installation. Do not probe deployments that
belong to other people.

## What happens next

- We aim to acknowledge reports promptly and to tell you whether it is a real
  issue, and how serious.
- We keep you informed while it is being fixed, and tell you when it ships.
- We credit you in the advisory, unless you would rather we did not.

If you do not hear back, assume it got lost — send it again
or email info@sebocorp.com. Silence is a failure on our side, not a
refusal.

## What we ask, and what we promise

We ask that you give us reasonable time to fix an issue before making it
public. There is no fixed embargo — it depends on severity and on how hard the
fix is, and we will agree it with you rather than impose it.

In return: we will not pursue anyone for good-faith security research on their
own installation. Reporting a problem is a favour to us, and it will be
treated as one.

There is no bug bounty and no monetary reward. What we can offer is credit in
the advisory, our thanks and a deep bow.

## Where to look

Skein is a multi-user tracker, so the interesting surface is mostly about
**who may see and do what**:

- visibility boundaries — reading issues, projects, comments or attachments
  belonging to a project you are not a member of;
- permission checks — performing an action reserved for an admin, or for the
  author of an issue;
- API keys and sessions — using someone else's credential, or keeping access
  after it was revoked;
- the MCP surface — an agent reaching data its principal cannot reach;
- the BFF proxy and the login path, including password login where an external
  identity provider is configured.

The three services are the backend (Go), the BFF (.NET) and the frontend
(React). Findings in dependencies are welcome too, if they are exploitable
through the way Skein uses them.

## Supported versions

Security fixes are released as a new version of the affected component. We do
not backport fixes to older versions — upgrade to the latest release to get
them.

## Not a vulnerability

To save your time and ours:

- missing hardening headers with no demonstrated impact;
- outdated dependency versions with no exploitable path in Skein;
- rate limiting on endpoints where it is not a security control;
- scanner output without a reproducible case;
- anything requiring an attacker who already has administrator access —
  administrators are trusted by design;
- the default credentials in the local docker-compose file: they are for local
  development and are documented as such.

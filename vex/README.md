# First-party VEX (accepted-risk suppressions)

`openvex.json` is this repo's mechanism for suppressing scanner findings —
instead of UI dismissals or a bare ignore-list, each suppression is an
[OpenVEX](https://openvex.dev) statement carrying a justification, reviewed
in a PR like any code change. `ci/scan.sh` passes it to trivy automatically
once it contains statements.

To suppress a finding, append to `statements` (and bump `version` +
`timestamp`):

```json
{
  "vulnerability": {"name": "CVE-2026-XXXXX"},
  "products": [
    {"@id": "pkg:oci/vector-fips"}
  ],
  "status": "not_affected",
  "justification": "vulnerable_code_not_in_execute_path",
  "impact_statement": "why, in one or two sentences — this is the audit trail"
}
```

Valid `status` values: `not_affected`, `fixed`, `under_investigation`,
`affected`. `justification` (required for `not_affected`):
`component_not_present`, `vulnerable_code_not_present`,
`vulnerable_code_not_in_execute_path`,
`vulnerable_code_cannot_be_controlled_by_adversary`,
`inline_mitigations_already_exist`.

Note the reporting split (see ci/scan.sh): GitHub Code Scanning alerts show
fixable findings only; the full inventory (including unfixed CVEs awaiting
Red Hat backports, and Rust-dependency findings read from the binary's
embedded cargo-auditable inventory) lives in the `trivy.json` artifact of
every run.

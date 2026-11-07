# Implementation record

Foundation milestone: `85e4399`.

Continuation implements the former core code gaps: authenticated SMAppService helper, product-scoped registration transactions, Full Install, root-owned shared-library swaps, repair review/execution, permission undo, copy/verify relocation, source identity and Trash, persistent logs/reports, crash recovery, bounded safe archive extraction, cancellation hardening, native helper Xcode target and Universal 2 embedding/signing.

Validation, signing setup and remaining external acceptance are documented in VALIDATION.md and SIGNING.md. The final development bundle is ad-hoc signed because no Apple identity is installed. Do not call administrator authorization or real NI acceptance tested until the signed build has been exercised on the target Mac.


Certificate-free continuation (2026-11-07): exact-build-approved XPC peers, native fixed-path setup/recovery, root launchd package, helper-removal package and release pipeline integration are implemented on the feature branch. The original release remains preserved on backup/pre-certificate-free-helper-2026-11-07 and in an external Git bundle. Automated results and remaining clean-Mac acceptance are recorded in VALIDATION.md and INSTALLER-HELPER.md.

# Implementation record

Foundation milestone: `85e4399`.

Continuation implements the former core code gaps: authenticated SMAppService helper, product-scoped registration transactions, Full Install, root-owned shared-library swaps, repair review/execution, permission undo, copy/verify relocation, source identity and Trash, persistent logs/reports, crash recovery, bounded safe archive extraction, cancellation hardening, native helper Xcode target and Universal 2 embedding/signing.

Validation, signing setup and remaining external acceptance are documented in VALIDATION.md and SIGNING.md. The final development bundle is ad-hoc signed because no Apple identity is installed. Do not call administrator authorization or real NI acceptance tested until the signed build has been exercised on the target Mac.

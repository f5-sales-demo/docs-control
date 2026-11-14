"""The reviewed caller keeps the shared digest and a scoped latest selector."""

SHARED_BUILDER_IMAGE = (
    "ghcr.io/f5-sales-demo/docs-builder@sha256:"
    "8fcc5e4171f6b4cb44133e44619aaca352d168b5a34e0c95a5715041d721bcda"
)
SHARED_BUILDER_SELECTOR = (
    "${{ github.repository == 'f5-sales-demo/certificate-management' && "
    "'ghcr.io/f5-sales-demo/docs-builder:latest' || '" + SHARED_BUILDER_IMAGE + "' }}"
)


def require_shared_builder_selector(selector: str) -> str:
    """Reject extra branches, foreign repositories and a changed shared digest."""
    assert selector == SHARED_BUILDER_SELECTOR
    return SHARED_BUILDER_IMAGE

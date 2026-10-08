from fastapi import HTTPException, Request, status


def is_local_client(request: Request) -> bool:
    """Returns True if request originates from localhost/loopback (local CLI, testclient, or SSH tunnel)."""
    client_ip = request.client.host if request.client else ""
    return client_ip in ("127.0.0.1", "::1", "localhost", "testclient")


def require_local_auth(request: Request) -> None:
    """Enforces that administrative actions strictly originate from localhost/SSH."""
    if not is_local_client(request):
        client_ip = request.client.host if request.client else "unknown"
        print(
            f"[SECURITY] Blocked remote administrative request from unauthorized IP: {client_ip}",
            flush=True,
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Administrative operations must originate from localhost via an SSH agent-authenticated session.",
        )

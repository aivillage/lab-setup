from rich.console import Console
from rich.text import Text

# AI Village Brand Theme Palette
GOLD = "#d4bd72"
STEEL_BLUE = "#67b1d7"
SAGE_GREEN = "#89c4a2"
MUTED_GREY = "#98a6b1"
CRIMSON = "#e06c75"
AMBER = "#e5c07b"

console = Console()


def print_header(title: str, subtitle: str = "") -> None:
    """Prints a styled section header with AI Village branding."""
    text = Text()
    text.append(title, style=f"bold {GOLD}")
    if subtitle:
        text.append(f" {subtitle}", style=MUTED_GREY)
    console.print()
    console.print(text)


def print_success(message: str) -> None:
    """Prints a success message."""
    console.print(f"[{SAGE_GREEN}][SUCCESS][/{SAGE_GREEN}] {message}")


def print_error(message: str) -> None:
    """Prints an error message."""
    console.print(f"[{CRIMSON}][ERROR][/{CRIMSON}] {message}")


def print_warning(message: str) -> None:
    """Prints a warning message."""
    console.print(f"[{AMBER}][WARN][/{AMBER}] {message}")


def print_info(message: str) -> None:
    """Prints an informational message."""
    console.print(f"[{STEEL_BLUE}]{message}[/{STEEL_BLUE}]")


def print_dim(message: str) -> None:
    """Prints a muted grey message."""
    console.print(f"[{MUTED_GREY}]{message}[/{MUTED_GREY}]")

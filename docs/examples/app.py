"""A tiny app: one documented function, one not."""


def greet(name):
    """Return a greeting for name."""
    return f"Hello, {name}"


def shout(name):
    return greet(name).upper()

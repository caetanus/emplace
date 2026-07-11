# Sphinx configuration for the emplace documentation.
# Build with:  sphinx-build -b html docs docs/_build

project = "emplace"
author = "Marcelo Aires Caetano"
copyright = "2026, Marcelo Aires Caetano"
release = "0.1.0"

extensions = []
templates_path = []
exclude_patterns = ["_build"]

# The RTD/furo theme if installed, else the built-in default.
try:
    import furo  # noqa: F401

    html_theme = "furo"
except ImportError:
    html_theme = "alabaster"

html_title = "emplace — GC-free data structures for D"
highlight_language = "d"

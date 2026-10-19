#!/usr/bin/env bash
# Renders the article Markdown to PDF with pandoc + xelatex.
#
# Usage: ./build-pdf.sh [article.md]
# Default input: energy-and-co2-measurement-for-java-applications.md
# Output: same basename with .pdf, next to the input.
#
# Requires: pandoc, xelatex (TeX Live / MacTeX with fvextra, xurl, float).

set -euo pipefail

cd "$(dirname "$0")"

input="${1:-energy-and-co2-measurement-for-java-applications.md}"
output="${input%.md}.pdf"

header="$(mktemp -t article-header).tex"
filter="$(mktemp -t article-filter).lua"
trap 'rm -f "$header" "$filter"' EXIT

# Allow line breaks in inline code after / . _ - = : (long paths, property names, URLs)
cat > "$filter" <<'EOF'
local escapes = {
  ["\\"] = "\\textbackslash{}", ["{"] = "\\{", ["}"] = "\\}",
  ["~"] = "\\textasciitilde{}", ["^"] = "\\textasciicircum{}",
  ["&"] = "\\&", ["%"] = "\\%", ["$"] = "\\$", ["#"] = "\\#", ["_"] = "\\_",
}

function Code(el)
  if not FORMAT:match("latex") then return nil end
  local text, out = el.text, {}
  for i = 1, #text do
    local c, next_c = text:sub(i, i), text:sub(i + 1, i + 1)
    out[#out + 1] = escapes[c] or c
    -- break only after a run of separators, so "://" stays together
    if c:match("[/%._%-=:]") and next_c ~= "" and not next_c:match("[/%._%-=:]") then
      out[#out + 1] = "\\allowbreak{}"
    end
  end
  return pandoc.RawInline("latex", "\\texttt{" .. table.concat(out) .. "}")
end
EOF

cat > "$header" <<'EOF'
% Wrap long code lines instead of running off the page
\usepackage{fvextra}
\RecustomVerbatimEnvironment{Highlighting}{Verbatim}{
  commandchars=\\\{\},
  breaklines, breakanywhere,
  breaksymbolleft={\tiny\ensuremath{\hookrightarrow}},
  fontsize=\small
}
\fvset{breaklines, breakanywhere, fontsize=\small}

% Break long URLs anywhere
\usepackage{xurl}

% Keep figures near where they appear in the text
\usepackage{float}
\floatplacement{figure}{!htbp}

% Caption styling
\usepackage[font=small, labelfont=bf, margin=1cm]{caption}

% Less cramped tables
\renewcommand{\arraystretch}{1.25}

% Avoid single lines at page breaks
\widowpenalty=10000
\clubpenalty=10000
EOF

# The first H1 becomes the document title, H2 sections become top-level sections.
pandoc "$input" \
  --from markdown \
  --pdf-engine=xelatex \
  --resource-path=. \
  --shift-heading-level-by=-1 \
  --syntax-highlighting=tango \
  --include-in-header="$header" \
  --lua-filter="$filter" \
  -V papersize=a4 \
  -V geometry:margin=2.5cm \
  -V fontsize=11pt \
  -V linestretch=1.15 \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue \
  -o "$output"

echo "Wrote $output"

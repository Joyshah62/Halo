# Sample documents

| File | What it is |
|---|---|
| `A Little Calculus.pdf` | Demo workbook (9 pages): inside/outside functions → power rule → chain rule → slopes. Built for "Why am I stuck?": problems 6 and 7 are the planted chain-rule mistakes, and page 5 holds the rule the agent quotes. |
| `Halo Practice Workbook.pdf` | Older 12-problem algebra + derivatives workbook, used by the checker tests. |

Each PDF is printed from the HTML beside it. Rebuild after editing (Chrome 125+; `--generate-pdf-document-outline` turns the `h1`/`h2` headings into the PDF outline, which Halo reads as chapters):

```bash
cd samples
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --no-pdf-header-footer \
  --generate-pdf-document-outline --print-to-pdf="A Little Calculus.pdf" "file://$PWD/calculus-workbook.html"
```

Keep the text layer clean for the agent's book search and page highlights: ligatures are turned off in the CSS, and a superscript should not be followed directly by punctuation (PDF text extraction breaks the line there).

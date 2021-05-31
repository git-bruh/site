#!/bin/sh

set -e

ROOT="${ROOT:-$(pwd)}"
GENDIR="${1:-$ROOT/gen}"

CMARK_ARGS="--unsafe"
CHROMA_ARGS="--html --html-only --html-lines --html-lines-table"

CHROMA_STYLE="github"

DATE_REGEX=".*[0-9]"
FILE_REGEX="<pre>{{include .*}}</pre>"

POSTS=

START='<!DOCTYPE html>
<html lang=en>
  <head>
    <title>{{ title }}</title>
    <link rel="stylesheet" href="style.css" type="text/css">
    <link rel="icon" type="image/png" sizes="64x64" href="favicon.png">
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
  </head>

<body><header>
    <nav>
      <a href=/>[Home]</a>
      <a href="https://git.git-bruh.duckdns.org">[Git]</a>
    </nav></header>
  <main>'
END='  </main>
</body>

</html>'

rm -rf "$GENDIR"
mkdir -p "$GENDIR"

datefmt() {
	DATE="$1"

	MONTHDAY="${DATE#*-}"
	YEAR="${DATE%%-*}"
	MONTH="${MONTHDAY%%-*}"
	DAY="${MONTHDAY#*-}"

	case "$MONTH" in
		01) MONTHNAME="Jan" ;;
		02) MONTHNAME="Feb" ;;
		03) MONTHNAME="Mar" ;;
		04) MONTHNAME="Apr" ;;
		05) MONTHNAME="May" ;;
		06) MONTHNAME="Jun" ;;
		07) MONTHNAME="Jul" ;;
		08) MONTHNAME="Aug" ;;
		09) MONTHNAME="Sep" ;;
		10) MONTHNAME="Oct" ;;
		11) MONTHNAME="Nov" ;;
		12) MONTHNAME="Dec" ;;
		*)  MONTHNAME="nil" ;;
	esac

	printf "%s" "$DAY $MONTHNAME $YEAR"
}

for markdown in $(find "$ROOT/blog/" -name "*.md" | sort -r); do
	basename="$(basename "$markdown" .md)"

	date="$(datefmt "$(printf %s "$basename" | grep -o "$DATE_REGEX")")"

	basename="$(printf %s "$basename" | sed "s/$DATE_REGEX-//")"

	# 'YYYY-MM-D-my-post' -> "My post"
	title="$(printf %s "$basename" | awk -vFS= -vOFS= \
		'{$1=toupper($1);gsub("-", " ");print $0}')"

	POSTS="$POSTS
      <tr>
         <td align=\"left\" class=\"index-post\">
            <a href=\"$basename.html\">$title</a>
         </td>
         <td align=\"right\" class=\"index-date\">$date</td>
      </tr>"

	# Temporary file to store the rendered markdown.
	cmark_tmpfile="$(mktemp)"

	# Word-splitting is intentional here.
	# shellcheck disable=2086
	cmark-gfm "$markdown" $CMARK_ARGS > "$cmark_tmpfile"

	grep -o "$FILE_REGEX" "$cmark_tmpfile" | while read -r file; do
		# '<pre>{{include "/files/myfile"}}</pre>' -> '$ROOT/files/myfile'.
		filepath="$ROOT/$(printf %s "$file" | grep -o '".*"' | tr -d \")"

		# Escape the slashes so that we can use the line with `sed`.
		file="$(printf %s "$file" | sed 's|/|\\/|g')"

		# Word-splitting is intentional here.
		# shellcheck disable=2086
		chroma $CHROMA_ARGS < "$filepath" |
		# Replace the "include" line with the syntax-highlighted contents.
		sed -i -e "/$file/{r /dev/stdin" -e "d;}" "$cmark_tmpfile"
	done

	# Add our boilerplate to the start and end of the file.
	printf "%s\n" "$(printf %s "$START" | sed "s/{{ title }}/$title/")" \
		   "$(cat "$cmark_tmpfile")" "$END" \
		> "$GENDIR/$basename.html"

	rm -f "$cmark_tmpfile"
done

printf "%s\n" "$(printf %s "$START" | sed "s/{{ title }}/site/")" \
	   "    <table>" "$POSTS" "    </table>" "$END" \
	> "$GENDIR/index.html"

cp -f "$ROOT/favicon.png" "$ROOT/style.css" "$GENDIR"

if [ -f "$ROOT/chroma.css" ]; then
	cat "$ROOT/chroma.css" >> "$GENDIR/style.css"
else
	chroma --html-styles --style="$CHROMA_STYLE" >> "$GENDIR/style.css"
fi

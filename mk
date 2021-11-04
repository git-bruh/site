#!/bin/sh

set -e

TITLE="site"
ROOT="${ROOT:-$(pwd)}"
GENDIR="${1:-$ROOT/gen}"
CMARK_ARGS="--unsafe"
CHROMA_ARGS="--html --html-only --html-lines --html-lines-table"
CHROMA_STYLE="github"

INDEX="$GENDIR/index.html"
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
	MONTHDAY="${1#*-}"
	YEAR="${1%%-*}"
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

printf "%s" "$START" | sed "s/{{ title }}/$TITLE/" > "$INDEX"
printf "\n    <table>\n" >> "$INDEX"

for markdown in "$ROOT/blog/"*.md; do
	date="${markdown##*/}"
	date="${date%%-[a-z]*}"
	date="$(datefmt "$date")" # Extract date
	basename="${markdown##*[0-9]-}" # Remove date
	basename="${basename%%.md}" # Remove extension

	# 'my-post' -> "My post"
	title="$(printf %s "$basename" | awk -vFS= -vOFS= \
		'{$1=toupper($1);gsub("-", " "); print $0}')"

	printf "%s\n" \
      "<tr>
         <td align=\"left\" class=\"index-post\">
            <a href=\"${basename}.html\">${title}</a>
         </td>
         <td align=\"right\" class=\"index-date\">${date}</td>
      </tr>" >> "$INDEX"

	post="$GENDIR/${basename}.html"

	printf "%s" "$START" | sed "s/{{ title }}/$title/" > "$post"
	printf "\n" >> "$post"

	# Word-splitting is intentional here.
	# shellcheck disable=2086
	cmark-gfm "$markdown" $CMARK_ARGS | while read -r line; do
		case "$line" in
			"<pre>{{include"*"}}</pre>")
				filename="${line##* \"}" # Extract upto first quote
				filename="$ROOT/${filename%%\"*}" # Remove everything after second quote

				[ -f "$filename" ] || {
					printf "File '%s' does not exist!\n" "$filename" >&2
					return 1
				}

				# Word-splitting is intentional here
				# shellcheck disable=2086
				chroma $CHROMA_ARGS "$filename" >> "$post"
				continue
			;;
		esac

		printf "%s\n" "$line" >> "$post"
	done

	printf "%s\n" "$END" >> "$post"
done

printf "    </table>\n%s\n" "$END" >> "$INDEX"

cp -f "$ROOT/favicon.png" "$ROOT/style.css" "$GENDIR"

if [ -f "$ROOT/chroma.css" ]; then
	cat "$ROOT/chroma.css" >> "$GENDIR/style.css"
else
	chroma --html-styles --style="$CHROMA_STYLE" >> "$GENDIR/style.css"
fi

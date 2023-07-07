#!/bin/sh

set -eu

: "${SITE_TITLE:=site}"
: "${SITE_STYLE_CSS=style.css}"
: "${SITE_FAVICON:=favicon.png}"

: "${ROOT:=$(pwd)}"
: "${ASSETS_DIR:=$ROOT/assets}"
: "${GENDIR:=$ROOT/gen}"
: "${BLOGDIR:=$ROOT/blog}"

MD_TO_HTML_AWK="$(dirname "$0")/md_to_html.awk"

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

get_md_basename() {
    markdown="$1"

    basename="${markdown##*[0-9]-}" # Remove date
    basename="${basename%%.md}" # Remove extension

    printf '%s\n' "$basename"
}

get_md_date() {
    markdown="$1"

    date="${markdown##*/}"
    date="${date%%-[a-z]*}"
    date="$(datefmt "$date")"

    printf '%s\n' "$date"
}

get_md_title() {
    get_md_basename "$1" |
      tr '-' ' ' |
      awk '{for (j = 1; j <= NF; j++) { $j = toupper(substr($j,1,1)) substr($j,2) }}1'
}

gen_table_elements() {
    for markdown in "$BLOGDIR"/*.md; do
        date="$(get_md_date "$markdown")"
        basename="$(get_md_basename "$markdown")"
        title="$(get_md_title "$markdown")"

        cat <<EOF
<tr>
  <td align="left">
    <a href="${basename}.html">${title}</a>
  </td>
  <td align="right">
    ${date}
  </td>
</tr>
EOF
    done
}

gen_page() {
    title="$1"

    cat <<EOF
<!DOCTYPE html>
<html lang=en>
  <head>
    <title>${title}</title>
    <link rel="stylesheet" href="${SITE_STYLE_CSS}" type="text/css">
    <link rel="icon" type="image/png" sizes="64x64" href="${SITE_FAVICON}">
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
  </head>

  <body>
    <main>
      <nav>
        <ul>
          <li><a href=/>home</a></li>
          <li><a href=/cv.pdf>cv</a></li>
        </ul>
      </nav>
$(cat /dev/stdin)
    </main>
  </body>
</html>
EOF
}

gen_main_page() {
    gen_page "${SITE_TITLE}" > "$GENDIR/index.html" <<EOF
    <table>
      $(gen_table_elements)
    </table>
EOF
}

gen_blog_page() {
    markdown="$1"

    basename="$(get_md_basename "$markdown")"
    title="$(get_md_title "$markdown")"

    gen_page "$title" > "$GENDIR/${basename}.html" <<EOF
<article align="left">
$(gawk -f "$MD_TO_HTML_AWK" < "$markdown")
</article>
EOF
}

main() {
    rm -rf "$GENDIR"
    mkdir -p "$GENDIR"

    gen_main_page

    for markdown in "$BLOGDIR"/*.md; do
        gen_blog_page "$markdown"
    done

    cp -f "$ASSETS_DIR"/* "$GENDIR/"

    cat "$GENDIR/chroma.css" >> "$GENDIR/style.css"
    rm -f "$GENDIR/chroma.css"
}

main

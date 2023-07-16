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
    printf '%s\n' "${1##*/}"
}

get_md_date() {
    dir="${1##*/}"
    printf '%s\n' "$(datefmt "$dir")"
}

get_md_title() {
    cat "$1/title"
}

sanitize_quotes() {
    sed 's/"/\&quot;/g' < "$1"
}

gen_og_tags() {
    og_title="$(sanitize_quotes "$1/title")"
    og_description="$(sanitize_quotes "$1/description")"
cat <<EOF
<meta property="og:type" content="article" />
<meta property="og:title" content="$og_title" />
<meta property="og:description" content="$og_description" />
EOF
}

gen_table_elements() {
    for page in $(printf '%s\n' "$BLOGDIR"/* | sort -ru); do
        date="$(get_md_date "$page")"
        basename="$(get_md_basename "$page")"
        title="$(get_md_title "$page")"

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
    og_tags="${2:-}"

    cat <<EOF
<!DOCTYPE html>
<html lang=en>
  <head>
    <title>${title}</title>
    <link rel="stylesheet" href="${SITE_STYLE_CSS}" type="text/css">
    <link rel="icon" type="image/png" sizes="64x64" href="${SITE_FAVICON}">
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    ${og_tags}
  </head>

  <body>
    <main>
      <nav>
        <ul>
          <li><a href=/>home</a></li>
          <li><a href=/resume.pdf>resume</a></li>
          <li><a href=https://github.com/git-bruh>github</a></li>
          <li><a href=https://twitter.com/git_bruh>twitter</a></li>
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
    page="$1"

    basename="$(get_md_basename "$page")"
    title="$(get_md_title "$page")"

    gen_page "$title" "$(gen_og_tags "$page")" > "$GENDIR/${basename}.html" <<EOF
<article align="left">
$(gawk -f "$MD_TO_HTML_AWK" < "$page/blog.md")
</article>
EOF
}

main() {
    rm -rf "$GENDIR"
    mkdir -p "$GENDIR"

    gen_main_page

    for post in "$BLOGDIR"/*; do
        gen_blog_page "$post"
    done

    cp -f "$ASSETS_DIR"/* "$GENDIR/"

    cat "$GENDIR/chroma.css" >> "$GENDIR/style.css"
    rm -f "$GENDIR/chroma.css"
}

main

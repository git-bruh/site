BEGIN {
    CODEBLOCK_COUNT = 0
    IN_CODEBLOCK = 0

    # Declare an array
    delete CODEBLOCK_BUFFERS[0]

    TOOL = "cmark-gfm --unsafe"
}

# ```, ```py, ```PY, ...
/^```([a-z|A-Z])?+$/ {
    IN_CODEBLOCK = !IN_CODEBLOCK

    if (IN_CODEBLOCK) {
        print sprintf("<pre>%d</pre>", CODEBLOCK_COUNT) |& TOOL

        lang = substr($0, 4)
        CODEBLOCK_BUFFERS[CODEBLOCK_COUNT,(IN_CODEBLOCK++ - 1)] = lang
    } else {
        CODEBLOCK_COUNT++
    }

    next
}

{
    if (IN_CODEBLOCK) {
        CODEBLOCK_BUFFERS[CODEBLOCK_COUNT,(IN_CODEBLOCK++ - 1)] = $0
    } else {
        print |& TOOL
    }
}

END {
    close(TOOL, "to")

    delete matches[0]

    while ((TOOL |& getline HTML_LINE) > 0) {
        if ((match (HTML_LINE, /<pre>([0-9]+)<\/pre>/, matches)) > 0) {
            block_number = matches[1]

            lang = CODEBLOCK_BUFFERS[block_number, 0]
            lang = length(lang) > 0 ? lang : "autodetect"

            cmd = sprintf("chroma --html --html-only --html-lines --html-lines-table --lexer=\"%s\"", lang)

            for (j = 1; (block_number, j) in CODEBLOCK_BUFFERS; j++) {
                print CODEBLOCK_BUFFERS[block_number, j] | cmd
            }

            close(cmd)
        } else {
            print HTML_LINE
        }
    }
}

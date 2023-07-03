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
            cmd = "chroma --html --html-only --html-lines --html-lines-table"
            block_number = matches[1]

            for (j = 0; (block_number, j) in CODEBLOCK_BUFFERS; j++) {
                print CODEBLOCK_BUFFERS[block_number, j] | cmd
            }

            close(cmd)
        } else {
            print HTML_LINE
        }
    }
}

## Self hosting `git`

In this post, I'll walk you through the steps for setting up a simple `git` server. We'll be using `git daemon` to serve our repositories, and `stagit` for the frontend.

## Requirements

* C99 compiler.
* Any `patch` implementation.
* POSIX complaint shell.
* ~15 minutes of your time.

## Setup

Assuming that you already have `git` installed on your system, the next step is to build our custom patched version of `stagit`.

For building [`stagit`](https://codemadness.org/git/stagit/), we'll require [`libgit2`](https://github.com/libgit2/libgit2), [`chroma`](https://github.com/alecthomas/chroma) and [`cmark-gfm`](https://github.com/github/cmark-gfm). The latter two are required by our patch for syntax highlighting and markdown rendering respectively, so make sure that you have all these dependencies installed. Now, we're ready to build `stagit`:

* Obtain the latest `stagit` release tarball from [codemadness.org](https://codemadness.org/releases/stagit/). The patch can be found in my personal [KISS repository](https://codeberg.org/git-bruh/kiss-repo/src/commit/54375a4b687b833e3954a86d1a6931d9fe1c8700/abandoned/stagit/patches/syntax-highlighting.patch). The features were originally implemented in [this](https://git.knutsen.co/stagit/) fork of `stagit`, which was further forked [here](https://sr.ht/~armaan/stagit/) to use `chroma` and `cmark-gfm` instead of slow `pygments`. All credits go to the authors of these two forks, I've just extracted their changes into a single patch.

* Apply the patch and build `stagit`:

```sh
patch -p1 < syntax-highlighting.patch

make && make install
```

Next, we're going to create a few helper scripts to save us some time. The scripts are taken from [this](https://hosakacorp.net/p/stagit-server.html) article with some modifications made to them.

Create a basic config file at `/etc/stagit/stagit.conf`:

```sh
GIT_HOME="/var/lib/git/repos"
WWW_HOME="/var/lib/git/home"
CLONE_URI="git://git.mydomain.tld"
DEFAULT_OWNER="username"
DEFAULT_DESCRIPTION="default description"
GIT_USER="git"
```

`post-receive`: `git` hook for updating the repository's frontend (Placed in `/etc/stagit`).

```sh
#!/bin/sh

# Fail if an unset variable is referenced (bad config).
set -eu

. /etc/stagit/stagit.conf

# The hook is called from the repository's root.
src="$(pwd)"
name=$(basename "$src")
dst="$WWW_HOME/$(basename "$name" '.git')"
mkdir -p "$dst"
cd "$dst"

echo "[stagit] building $dst"
stagit "$src"

echo "[stagit] linking $dst"
ln -sf log.html index.html

for file in style.css logo.png; do
    ln -sf "../$file" "$file"
done

stagit-gen-index
```

Place the following scripts somewhere in `PATH`:

`stagit-gen-index`: Updating the repository index when creating a new repo.

```sh
#!/bin/sh

# Fail if an unset variable is referenced (bad config).
set -eu

. /etc/stagit/stagit.conf

stagit-index "$GIT_HOME"/*.git > "$WWW_HOME/index.html"
```

`stagit-new-repo`: Creating a new repository with some boilerplate.

```sh
#!/bin/sh

# Fail if an unset variable is referenced (bad config).
set -eu

. /etc/stagit/stagit.conf

if [ $# -gt 1 ]; then
        DESC="$2"
else
        DESC="$DEFAULT_DESCRIPTION"
fi

if [ $# -eq 0 ]; then
        printf "not enough args\n" >&2
        exit 1
else
        REPO="$(basename "$1")"
fi

git init --bare "$GIT_HOME/$REPO.git"

# Share a common `git` hook between repositories.
ln -sf "/etc/stagit/post-receive" "$GIT_HOME/$REPO.git/hooks/post-receive"

echo "$CLONE_URI/$REPO.git" > "$GIT_HOME/$REPO.git/url"
echo "$DEFAULT_OWNER" > "$GIT_HOME/$REPO.git/owner"

# Ensure that `git daemon` allows repository cloning.
:> "$GIT_HOME/$REPO.git/git-daemon-export-ok"

echo "$DESC" > "$GIT_HOME/$REPO.git/description"

mkdir "$WWW_HOME/$REPO"
```

Now set up a separate user to serve our repositories:

```sh
adduser git
for dir in repos home; do mkdir -p "/var/lib/git/$dir"; done
chown -R git:git /var/lib/git
su - git
mkdir -p ~/.ssh
echo "My public SSH key" >> ~/.ssh/authorized_keys # For pushing to repos.
```

Almost there, create a `git daemon` service for your init system. The following steps are to be followed for `runit` based systems (Specifics might vary depending on your distribution):

```sh
mkdir -p /etc/sv/git-daemon

cat > /etc/sv/git-daemon/run << EOF
#!/bin/sh

. /etc/stagit/stagit.conf

# Run `git daemon` as our `git` user (security).
exec chpst -u git git daemon --base-path="\$GIT_HOME"
EOF

ln -s /run/runit/supervise.git-daemon /etc/sv/git-daemon/supervise
ln -s /etc/sv/git-daemon /var/service/ # Enable the service
```

Finally, serve the generated pages through your web server. This should be enough for caddy users:

```
root * /var/lib/git/home
file_server
```

## Usage

Now that we have our scripts and daemons set up, we're gonna create our first repository and add some CSS!

```sh
su - git
stagit-new-repo hello-world

# On the dev system:
SSH_PORT=1234
git clone "ssh://git@git.mydomain.tld:$SSH_PORT/var/lib/git/repos/hello-world.git"
cd hello-world; echo "# Hello" > README.md
git add README.md; git commit -m "Hello World!"
git push
```

CSS can be generated with the help of `chroma` itself, though you'll need to add regular CSS yourself. Here's an example for generating an emacs-themed CSS:

```sh
. /etc/stagit/stagit.conf
chroma --html-styles --style=emacs > "$WWW_HOME/style.css"
```

When creating a new repository, `stagit-gen-index` should be run on the server _AFTER_ pushing the first commit. Similarly, it must be run when a repository is deleted.

**TIP:** The value of `GIT_HOME` in `/etc/stagit/stagit.conf` can be changed to `/home/git` to shorten the cloning URL to `ssh://git@git.mydomain.tld:$SSH_PORT/~git/hello-world.git`.

There you have it, a simple `git` server with a beautiful JS-free frontend! ~~See mine in action [here]().~~

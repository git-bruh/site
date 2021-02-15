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

* Obtain the latest `stagit` release tarball from [codemadness.org](https://codemadness.org/releases/stagit/). The patch can be found in my personal [KISS repository](https://git.git-bruh.duckdns.org/kiss-repo/file/repo/stagit/patches/syntax-highlighting.patch.html). The features were originally implemented in [this](https://git.knutsen.co/stagit/) fork of `stagit`, which was further forked [here](https://sr.ht/~armaan/stagit/) to use `chroma` and `cmark-gfm` instead of slow `pygments`. All credits go to the authors of these two forks, I've just extracted their changes into a single patch.

* Apply the patch and build `stagit`:

<pre>{{include "/files/stagit-build.sh"}}</pre>

Next, we're going to create a few helper scripts to save us some time. The scripts are taken from [this](https://hosakacorp.net/p/stagit-server.html) article with some modifications made to them.

Create a basic config file at `/etc/stagit/stagit.conf`:

<pre>{{include "/files/stagit-conf.sh"}}</pre>

`post-receive`: `git` hook for updating the repository's frontend (Placed in `/etc/stagit`).

<pre>{{include "/files/stagit-receive.sh"}}</pre>

Place the following scripts somewhere in `PATH`:

`stagit-gen-index`: Updating the repository index when creating a new repo.

<pre>{{include "/files/stagit-index.sh"}}</pre>

`stagit-new-repo`: Creating a new repository with some boilerplate.

<pre>{{include "/files/stagit-repo.sh"}}</pre>

Now set up a separate user to serve our repositories:

<pre>{{include "/files/stagit-user.sh"}}</pre>

Almost there, create a `git daemon` service for your init system. The following steps are to be followed for `runit` based systems (Specifics might vary depending on your distribution):

<pre>{{include "/files/git-daemon.sh"}}</pre>

Finally, serve the generated pages through your web server. This should be enough for caddy users:

<pre>{{include "/files/stagit-caddy.sh"}}</pre>

## Usage

Now that we have our scripts and daemons set up, we're gonna create our first repository and add some CSS!

<pre>{{include "/files/stagit-usage.sh"}}</pre>

CSS can be generated with the help of `chroma` itself, though you'll need to add regular CSS yourself. Here's an example for generating an emacs-themed CSS:

<pre>{{include "/files/stagit-css.sh"}}</pre>

When creating a new repository, `stagit-gen-index` should be run on the server _AFTER_ pushing the first commit. Similarly, it must be run when a repository is deleted.

**TIP:** The value of `GIT_HOME` in `/etc/stagit/stagit.conf` can be changed to `/home/git` to shorten the cloning URL to `ssh://git@git.mydomain.tld:$SSH_PORT/~git/hello-world.git`.

There you have it, a simple `git` server with a beautiful JS-free frontend! See mine in action [here](https://git.git-bruh.duckdns.org).

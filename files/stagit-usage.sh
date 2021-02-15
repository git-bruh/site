su - git
stagit-new-repo hello-world

# On the dev system:
SSH_PORT=1234
git clone "ssh://git@git.mydomain.tld:$SSH_PORT/var/lib/git/repos/hello-world.git"
cd hello-world; echo "# Hello" > README.md
git add README.md; git commit -m "Hello World!"
git push

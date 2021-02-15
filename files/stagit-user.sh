adduser git
for dir in repos home; do mkdir -p "/var/lib/git/$dir"; done
chown -R git:git /var/lib/git
su - git
mkdir -p ~/.ssh
echo "My public SSH key" >> ~/.ssh/authorized_keys # For pushing to repos.

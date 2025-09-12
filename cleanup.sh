git branch -r | grep -v "main" | sed 's/origin\///' | xargs git push origin --delete
git branch | grep -v "main" | xargs git branch -D
git checkout main
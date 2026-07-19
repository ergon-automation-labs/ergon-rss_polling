
bump-version:
	@if [ -z "$(BUMP)" ]; then echo "Usage: make bump-version BUMP=major|minor|patch"; exit 1; fi
	@OLD=$$(grep 'version:' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/'); \
	bash $(SCRIPTS_DIRECTORY)/bump_version.sh mix.exs $(BUMP) > /dev/null; \
	NEW=$$(grep 'version:' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/'); \
	echo "✓ Bumped: $$OLD → $$NEW"

push: test compile credo
	@echo "✅ All validations passed"
	@echo "$$(date +%s)" > .push-validated
	@echo "✓ Proof-of-validation created"
	@$(MAKE) git-push


git-push:
	@git push origin main 2>&1 | tail -3

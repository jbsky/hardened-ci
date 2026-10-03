.PHONY: build check

# versions.json est la seule source : le Dockerfile n'a aucune valeur par
# defaut, les build-args passent par scripts/versions-build-args.py, qui
# refuse une valeur absente, nulle ou vide. Un echec du generateur arrete
# la recette (pas de $(shell ...), qui l'avalerait).
build:
	@args=$$(./scripts/versions-build-args.py --docker) \
	  && echo "Build depuis versions.json : $$args" \
	  && DOCKER_BUILDKIT=1 docker compose build $$args app

check:
	python3 -m unittest discover -s scripts -p 'test_versions_build_args.py'
	./scripts/versions-build-args.py --check

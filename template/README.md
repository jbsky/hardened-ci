# Gabarit d'image durcie

Point de depart d'un nouveau depot `<app>-hardened`. Il ne contient que ce
qui doit etre vrai **des le premier commit** ; le reste (telechargement
verifie, compilation durcie, stage `prep` scanne, cloture, manifeste,
publication signee) s'ajoute ensuite, sans casser ce qui suit.

```sh
./scripts/new-image.sh ../<app>-hardened   # depuis la racine de hardened-ci
```

`new-image.sh` copie ce gabarit et y ajoute les scripts partages depuis leur
copie de reference (`hardened-ci/scripts/`) : le gabarit n'en porte aucune
copie qui pourrait deriver.

## Deja en place : versions.json fait autorite

- `versions.json` est le **seul** endroit ou une version s'ecrit ;
- le `Dockerfile` n'a aucune valeur par defaut et echoue au garde si un
  build-arg manque ;
- `make build` et la CI passent les build-args par
  `scripts/versions-build-args.py` ;
- le job `lint` lance `--check` et son test unitaire, le job `build` l'action
  `jbsky/hardened-ci/versions` (epinglee par SHA, Dependabot la bumpe).

En ajoutant une dependance : une cle dans `versions.json` (`foo`, `foo_sha256`),
l'`ARG` correspondant (`FOO_VERSION`, `FOO_SHA256`) sans valeur, et une ligne
de plus dans le garde. `make check` dit ce qui manque.

La CI de hardened-ci instancie ce gabarit a chaque PR et verifie qu'il passe
le controle, que le controle echoue quand on y injecte une version en dur,
qu'un build sans argument echoue au garde, et que l'image construite porte
bien la version de `versions.json`.

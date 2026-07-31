# Policy Vault : lecture seule des secrets de l'appli nginx-test-vault dans le moteur lab-kv/.
# Moindre privilège : l'appli ne voit QUE son sous-dossier nginx-test-vault/, rien d'autre.
# KV-v2 => les données sont sous <mount>/data/<path> et les métadonnées sous <mount>/metadata/<path>.

path "lab-kv/data/nginx-test-vault/*" {
  capabilities = ["read"]
}

path "lab-kv/metadata/nginx-test-vault/*" {
  capabilities = ["read"]
}

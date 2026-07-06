# Single-node ES for local-es-memory. Pinned to 9.4.2 to match the home ES
# cluster (cookbooks/lxc-elasticsearch). The memory-v2 indices use the
# `ja_en_hybrid` analyzer (kuromoji_tokenizer) — a hard dependency the stock
# image lacks, so es_backend.ensure_indices() PUT would fail without it.
FROM docker.elastic.co/elasticsearch/elasticsearch:9.4.2

RUN bin/elasticsearch-plugin install --batch analysis-kuromoji

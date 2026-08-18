#!/bin/sh -

curl https://live-go-cam.geneontology.io/product/json/provider-to-model.json |
    jq . > /tmp/provider-to-model.json

jq '."http://flybase.org"' /tmp/provider-to-model.json |
  perl -ne 'print "$1\n" if /.*"(.*)".*/' > latest-fly-gocam-ids.txt

echo -n 'model count: '; wc -l latest-fly-gocam-ids.txt

for id in `cat latest-fly-gocam-ids.txt`
do
    curl -s https://live-go-cam.geneontology.io/product/yaml/go-cam/$id.yaml > go-cams/$id.yaml
done

#!/bin/bash -

set -eu
set -o pipefail

version=$1
dump_dir=$2

container_dir=.

(cd pombase-website; git pull)
(cd pombase-chado; git pull)
(cd pombase-chado-json; git pull)
(cd pombase-python-web; git pull)
(cd curation; git pull)
(cd pombase-fly-query; git pull)

(cd pombase-website; rsync -avHSP src/fly-query/index.html src/)

(cd pombase-website/src/assets
 ln -sf fly-query-logo.png logo.png
 ln -sf fly-query-logo-small.png logo-small.png
 ln -sf fly-query-logo-tiny.png logo-tiny.png)

rsync -avHSP pombase-fly-query/setup_jbrowse2_in_container.sh $container_dir/container_scripts/
rsync -avHSP pombase-website/etc/PomBasePlugin.js $container_dir/PomBasePlugin.js
rsync -avHSP pombase-fly-query/site_config.json $container_dir/main_config.json

rsync -aL --delete-after --exclude '*~' pombase-chado/etc/docker-conf/ $container_dir/conf/

rsync -acvPHS --delete-after $dump_dir/web-json $container_dir/
rsync -acvPHS --delete-after $dump_dir/misc $container_dir/
rsync -acvPHS --delete-after $dump_dir/gff $container_dir/
rsync -acvPHS --delete-after $dump_dir/fasta/chromosomes/ $container_dir/chromosome_fasta/
rsync -acvPHS --delete-after $dump_dir/fasta/bgzip_chromosomes/ $container_dir/bgzip_chromosomes/

rsync -acvHSP $dump_dir/api_maps.sqlite3.zst $container_dir/
rsync -acvHSP $dump_dir/pombe-embl/supporting_files/PB_references.txt $container_dir/

mkdir -p $container_dir/feature_sequences
rsync -acvPHS --delete-after $dump_dir/fasta/feature_sequences/peptide.fa.gz $container_dir/feature_sequences/peptide.fa.gz

pombase-chado/etc/create_jbrowse_track_list.pl \
   $container_dir/pombase-fly-query/trackListTemplate.json \
   $container_dir/pombase-fly-query/jbrowse_track_metadata.csv \
   $container_dir/trackList.json $container_dir/jbrowse_track_metadata.csv \
   $container_dir/minimal_jbrowse_track_list.json

touch $container_dir/jbrowse2_config.json

echo building container ...
docker build -f conf/Dockerfile-main --build-arg database_name=fly-query --build-arg target=prod -t=fly-query/web:$version-prod .

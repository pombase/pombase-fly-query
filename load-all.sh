#!/bin/bash -

date

set -eu
set -o pipefail

HOST="$1"
BUILD_ID="$2"
USER="$3"
PASSWORD="$4"

die() {
  echo $1 1>&2
  exit 1
}

BASE=`pwd`

GIT_DIR=$BASE/pombase-fly-query

POMCUR=/var/pomcur
SOURCES=$POMCUR/sources
FLY_QUERY_SOURCES=$POMCUR/_sources

DB=fly-query-$BUILD_ID

WWW_DIR=/var/www/pombase
DUMPS_DIR=$WWW_DIR/fly_query_nightly
BUILDS_DIR=$DUMPS_DIR/builds
CURRENT_BUILD_DIR=$BUILDS_DIR/$DB

LOAD_CONFIG=$GIT_DIR/load-chado.yaml
MAIN_CONFIG=$GIT_DIR/site_config.json

LOG_DIR=$BASE/logs

POMBASE_CHADO=$BASE/pombase-chado
POMBASE_LEGACY=$BASE/pombase-legacy

(cd chobo/; git pull) || die "Failed to update Chobo"

(cd pombase-chado; git pull) || die "Failed to update pombase-chado"
(cd pombase-legacy; git pull) || die "Failed to update pombase-legacy"

(cd pombase-website; git pull) || die "Failed to update pombase-website"

cd pombase-legacy

POMBASE_LEGACY=`pwd`

export PATH=BASE/chobo/script/:/usr/local/owltools-v0.3.0-74-gee0f8bbd/OWLTools-Runner/bin/:$PATH
export CHADO_CLOSURE_TOOL=$BASE/pombase-chado/script/relation-graph-chado-closure.pl
export PERL5LIB=$POMBASE_CHADO/lib:$POMBASE_LEGACY/lib:$BASE/chobo/lib/:$PERL5LIB


#time nice -19 $GIT_DIR/make-db $BASE $DATE "$HOST" $USER $PASSWORD) || die "make-db failed"

echo "building database: $BUILD_ID on $HOST"

createdb --locale 'C' --template template0 --encoding 'UTF8' $DB

echo Loading template

perl -pne 's/kmr44/japonicus/g' $POMBASE_LEGACY/pombase-chado-base.dump | psql -q $DB |
  perl -ne 'if (/^\s*setval\s*$/) {
              my $l2 = <>; if ($l2 =~ /-----/) { my $l3 = <>; if ($l3 =~ /^\s*\d+/) { my $l4 = <>; if ($l4 !~ /\(\d+ row/) { print } } }
            } else { print unless /^\s*$/ }'

(cd $FLY_QUERY_SOURCES/; wget -N http://purl.obolibrary.org/obo/go/snapshot/go-basic.obo)

PROCESSED_MINI_PRO_OBO=/tmp/processed_mini_pro_$(id -un)_$$.obo
$BASE/pombase-legacy/etc/process_pombe_mini_pr.pl $FLY_QUERY_SOURCES/pombe-embl/mini-ontologies/pombe_mini_PR.obo > $PROCESSED_MINI_PRO_OBO

GO_OBO=go-basic.obo

OBO_FILES="\
 obo-relations/src/ontology/subsets/ro-chado.obo \
 SO-Ontologies-git/Ontology_Files/so-simple.obo \
 psi-mod-CV/PSI-MOD.obo \
 pato-simple.obo \
 pombe-embl/mini-ontologies/iao.obo \
 pombe-embl/mini-ontologies/quiescence.obo \
 pombase_fypo_github/supplemental_files/fypo_extension_relations.obo \
 pombe-embl/mini-ontologies/fypo_extension.obo \
 pombe-embl/mini-ontologies/chebi.obo \
 pombe-embl/mini-ontologies/cl.obo \
 $PROCESSED_MINI_PRO_OBO \
 pombe-embl/mini-ontologies/gene_ex_extension_relations.obo \
 pombe-embl/mini-ontologies/PSI-MOD_extension_relations.obo \
 pombe-embl/mini-ontologies/SO_feature_relations.obo \
 pombe-embl/mini-ontologies/has_qualifier_range.obo \
 pombe-embl/mini-ontologies/pombase_gene_expression_ontology.obo \
 fypo-simple-pombase.obo \
 mondo-simple.obo \
 $GO_OBO"

CONNECT_STRING="dbi:Pg:dbname=$DB"
if [ x$HOST != x ]
then
    CONNECT_STRING="$CONNECT_STRING;host=$HOST"
fi

CHOBO_LOAD_LOG=chobo_load.log
echo 'Starting OBO loading at:' `date`
echo log file: $CHOBO_LOAD_LOG
OLD_DIR=`pwd`
cd $FLY_QUERY_SOURCES
if $BASE/chobo/script/chobo_load $CONNECT_STRING $USER $PASSWORD $POMBASE_LEGACY/etc/pombase-relations.obo $OBO_FILES \
   gmod-schema-latest/chado/load/etc/feature_property.obo \
   pombase_fypo_github/fyeco.obo pombase_terms-latest.obo > $CHOBO_LOAD_LOG 2>&1
then
  echo 'Finished OBO loading at:' `date`
else 
  echo chobo_load failed:
  cat $CHOBO_LOAD_LOG
  exit 1
fi

cd $OLD_DIR

date
echo populate cvtermpath using owltools
export OWLTOOLS_MEMORY=20g
(cd $FLY_QUERY_SOURCES; $CHADO_CLOSURE_TOOL $HOST $DB $USER $PASSWORD $OBO_FILES)

date; echo finished

psql -q $DB -c "UPDATE cv SET name = 'mondo' WHERE name LIKE 'mondo/%';"

# prevent duplicate feature uniquenames
psql -q $DB -c 'CREATE UNIQUE INDEX pombase_feature_uniquename_unique_idx ON feature(uniquename);'

psql -q $DB -c 'CREATE INDEX pombase_cvtermsynonym_synonym_idx1 on cvtermsynonym(synonym);'

# view definitions for extension terms
psql -q $DB -c "CREATE materialized VIEW pombase_feature_cvterm_with_ext_parents AS
SELECT fc.feature_cvterm_id,
       fc.feature_id,
       pub_id,
       parent_t.name AS base_cvterm_name,
       parent_t.cvterm_id AS base_cvterm_id,
       parent_cv.name AS base_cv_name,
       child_t.name AS cvterm_name,
       child_t.cvterm_id AS cvterm_id
FROM feature_cvterm fc
JOIN cvterm child_t ON child_t.cvterm_id = fc.cvterm_id
JOIN cvterm_relationship r ON child_t.cvterm_id = r.subject_id
JOIN cvterm parent_t ON r.object_id = parent_t.cvterm_id
JOIN cv parent_cv ON parent_cv.cv_id = parent_t.cv_id
JOIN cv child_cv ON child_cv.cv_id = child_t.cv_id
JOIN cvterm r_type ON r.type_id = r_type.cvterm_id
WHERE r_type.name = 'is_a'
  AND child_cv.name = 'PomBase annotation extension terms';"

psql -q $DB -c "CREATE materialized VIEW pombase_feature_cvterm_no_ext_terms AS
SELECT fc.feature_cvterm_id,
       fc.feature_id,
       pub_id,
       t.name AS base_cvterm_name,
       t.cvterm_id AS base_cvterm_id,
       cv.name AS base_cv_name,
       t.name AS cvterm_name,
       t.cvterm_id
FROM feature_cvterm fc
JOIN cvterm t ON t.cvterm_id = fc.cvterm_id
JOIN cv ON cv.cv_id = t.cv_id
WHERE cv.name <> 'PomBase annotation extension terms';"

psql -q $DB -c "CREATE materialized VIEW pombase_feature_cvterm_ext_resolved_terms AS
 SELECT *
   FROM pombase_feature_cvterm_no_ext_terms
UNION
 SELECT *
   FROM pombase_feature_cvterm_with_ext_parents;"

psql -q $DB -c "CREATE INDEX pombase_feature_cvterm_ext_resolved_terms_feature_id_idx ON pombase_feature_cvterm_ext_resolved_terms(feature_id);"
psql -q $DB -c "CREATE INDEX pombase_feature_cvterm_ext_resolved_terms_cvterm_id_idx ON pombase_feature_cvterm_ext_resolved_terms(cvterm_id);"
psql -q $DB -c "CREATE INDEX pombase_feature_cvterm_ext_resolved_terms_cvterm_name_idx ON pombase_feature_cvterm_ext_resolved_terms(cvterm_name);"
psql -q $DB -c "CREATE INDEX pombase_feature_cvterm_ext_resolved_terms_base_cvterm_id_idx ON pombase_feature_cvterm_ext_resolved_terms(base_cvterm_id);"
psql -q $DB -c "CREATE INDEX pombase_feature_cvterm_ext_resolved_terms_base_cvterm_name_idx ON pombase_feature_cvterm_ext_resolved_terms(base_cvterm_name);"

psql -q $DB -c "CREATE MATERIALIZED VIEW pombase_extension_rels_and_values AS SELECT t.cvterm_id AS cvterm_id,
 substring(pt.name FROM 'annotation_extension_relation-(.*)') AS rel_name, p.value AS value FROM
 cvtermprop p JOIN cvterm pt ON p.type_id = pt.cvterm_id JOIN cvterm t ON
 p.cvterm_id = t.cvterm_id
 WHERE pt.name LIKE 'annotation_extension_relation-%' AND t.cvterm_id IN
 (SELECT subject_id FROM cvterm_relationship WHERE object_id IN (SELECT
 cvterm_id FROM cvterm WHERE cv_id = (SELECT cv_id FROM cv WHERE name =
 'fission_yeast_phenotype'))) UNION ALL SELECT rel.subject_id as cvterm_id,
 rel_type.name as rel_name, object.name as value from cvterm_relationship rel join cvterm rel_type on
 rel.type_id = rel_type.cvterm_id join cvterm object on rel.object_id = object.cvterm_id
 where rel.subject_id in (select subject_id from
 cvterm_relationship where object_id in (select cvterm_id from cvterm where
 cv_id = (select cv_id from cv where name = 'fission_yeast_phenotype'))) and
 rel_type.cv_id = (select cv_id from cv where name = 'fypo_extension_relations');"

psql -q $DB <<'EOF'
CREATE MATERIALIZED VIEW pombase_genes_annotations_dates AS
  WITH
  pub_community_curated_flags AS
  (SELECT DISTINCT pub.pub_id, (value = 'community') AS flag
    FROM pubprop date_prop join pub on pub.pub_id = date_prop.pub_id
    JOIN cvterm prop_type on date_prop.type_id = prop_type.cvterm_id
   WHERE prop_type.name = 'canto_curator_role')
 SELECT gene.uniquename AS gene_uniquename,
        'FC:' || fc.feature_cvterm_id AS id, pub.uniquename AS pmid,
   (SELECT value FROM organismprop p WHERE p.organism_id = organism.organism_id) AS taxonid,
   (SELECT flag FROM pub_community_curated_flags fl WHERE fl.pub_id = pub.pub_id) AS publication_community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) AS annotation_date,
   substring((SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) FROM E'^(\\d\\d\\d\\d)')::integer AS annotation_year,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) AS session,
   array_to_string(array (SELECT distinct(value)
    FROM feature_cvtermprop curator_name_prop
    WHERE fc.feature_cvterm_id = curator_name_prop.feature_cvterm_id
      AND curator_name_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'curator_name')), ',') AS curator_name,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'community_curated'))::boolean AS community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'annotation_throughput_type') limit 1) AS annotation_throughput_type,
   (SELECT distinct(value)
    FROM feature_cvtermprop evidence_prop
    WHERE fc.feature_cvterm_id = evidence_prop.feature_cvterm_id
      AND evidence_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'evidence')) AS evidence_code,
   (SELECT distinct(value)
    FROM feature_cvtermprop assigned_by_prop
    WHERE fc.feature_cvterm_id = assigned_by_prop.feature_cvterm_id
      AND assigned_by_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'assigned_by')) AS annotation_source,
   (SELECT distinct(value)
    FROM feature_cvtermprop source_file_prop
    WHERE fc.feature_cvterm_id = source_file_prop.feature_cvterm_id
      AND source_file_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_file')) AS source_file,
   base_cv_name AS annotation_type
 FROM feature gene
 JOIN organism ON gene.organism_id = organism.organism_id
 JOIN cvterm gene_type ON gene_type.cvterm_id = gene.type_id
 JOIN feature_relationship r ON r.object_id = gene.feature_id
 JOIN cvterm rel_type ON r.type_id = rel_type.cvterm_id
 JOIN pombase_feature_cvterm_ext_resolved_terms fc ON gene.feature_id = fc.feature_id
 JOIN pub ON fc.pub_id = pub.pub_id
 WHERE rel_type.name = 'part_of'
   AND gene_type.name = 'gene'
 UNION
 SELECT gene.uniquename AS gene_uniquename,
        'FC:' || fc.feature_cvterm_id AS id, pub.uniquename AS pmid,
   (SELECT value FROM organismprop p WHERE p.organism_id = organism.organism_id) AS taxonid,
   (SELECT flag FROM pub_community_curated_flags fl WHERE fl.pub_id = pub.pub_id) as publication_community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) AS annotation_date,
   substring((SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) FROM E'^(\\d\\d\\d\\d)')::integer AS annotation_year,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) AS session,
   array_to_string(array (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'curator_name')), ',') AS curator_name,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'community_curated'))::boolean AS community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'annotation_throughput_type') limit 1) AS annotation_throughput_type,
   (SELECT distinct(value)
    FROM feature_cvtermprop evidence_prop
    WHERE fc.feature_cvterm_id = evidence_prop.feature_cvterm_id
      AND evidence_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'evidence')) AS evidence_code,
   (SELECT distinct(value)
    FROM feature_cvtermprop assigned_by_prop
    WHERE fc.feature_cvterm_id = assigned_by_prop.feature_cvterm_id
      AND assigned_by_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'assigned_by')) AS annotation_source,
   (SELECT distinct(value)
    FROM feature_cvtermprop source_file_prop
    WHERE fc.feature_cvterm_id = source_file_prop.feature_cvterm_id
      AND source_file_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_file')) AS source_file,
   base_cv_name AS annotation_type
 FROM feature gene
 JOIN organism ON gene.organism_id = organism.organism_id
 JOIN cvterm gene_type ON gene_type.cvterm_id = gene.type_id
 JOIN feature_relationship r ON r.object_id = gene.feature_id
 JOIN cvterm rel_type ON r.type_id = rel_type.cvterm_id
 JOIN feature mrna ON mrna.feature_id = subject_id
 JOIN cvterm rna_type ON rna_type.cvterm_id = mrna.type_id
 JOIN pombase_feature_cvterm_ext_resolved_terms fc ON mrna.feature_id = fc.feature_id
 JOIN pub ON fc.pub_id = pub.pub_id
 WHERE rel_type.name = 'part_of'
   AND gene_type.name = 'gene'
   AND rna_type.name like '%RNA'
 UNION
 SELECT gene.uniquename AS gene_uniquename,
        'FC:' || fc.feature_cvterm_id AS id, pub.uniquename AS pmid,
   (SELECT value FROM organismprop p WHERE p.organism_id = organism.organism_id) AS taxonid,
   (SELECT flag FROM pub_community_curated_flags fl WHERE fl.pub_id = pub.pub_id) as publication_community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) AS annotation_date,
   substring((SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) FROM E'^(\\d\\d\\d\\d)')::integer AS annotation_year,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) AS session,
   array_to_string(array (SELECT distinct(value)
     FROM feature_cvtermprop curator_name_prop
    WHERE fc.feature_cvterm_id = curator_name_prop.feature_cvterm_id
      AND curator_name_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'curator_name')), ',') AS curator_name,
   (SELECT distinct(value)
    FROM feature_cvtermprop community_curated_prop
    WHERE fc.feature_cvterm_id = community_curated_prop.feature_cvterm_id
      AND community_curated_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'community_curated'))::boolean AS community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop annotation_throughput_type_prop
    WHERE fc.feature_cvterm_id = annotation_throughput_type_prop.feature_cvterm_id
      AND annotation_throughput_type_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'annotation_throughput_type') limit 1) AS annotation_throughput_type,
   (SELECT distinct(value)
    FROM feature_cvtermprop evidence_prop
    WHERE fc.feature_cvterm_id = evidence_prop.feature_cvterm_id
      AND evidence_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'evidence')) AS evidence_code,
   (SELECT distinct(value)
    FROM feature_cvtermprop assigned_by_prop
    WHERE fc.feature_cvterm_id = assigned_by_prop.feature_cvterm_id
      AND assigned_by_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'assigned_by')) AS annotation_source,
   (SELECT distinct(value)
    FROM feature_cvtermprop source_file_prop
    WHERE fc.feature_cvterm_id = source_file_prop.feature_cvterm_id
      AND source_file_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_file')) AS source_file,
   base_cv_name AS annotation_type
 FROM feature gene
 JOIN organism ON gene.organism_id = organism.organism_id
 JOIN cvterm gene_type ON gene_type.cvterm_id = gene.type_id
 JOIN feature_relationship allele_gene_rel ON allele_gene_rel.object_id = gene.feature_id
 JOIN feature allele ON allele.feature_id = allele_gene_rel.subject_id
 JOIN cvterm allele_gene_rel_type ON allele_gene_rel.type_id = allele_gene_rel_type.cvterm_id
 JOIN feature_relationship allele_genotype_rel ON allele_genotype_rel.subject_id = allele.feature_id
 JOIN feature genotype ON allele_genotype_rel.object_id = genotype.feature_id
 JOIN cvterm allele_genotype_rel_type ON allele_genotype_rel.type_id = allele_genotype_rel_type.cvterm_id
 JOIN pombase_feature_cvterm_ext_resolved_terms fc ON genotype.feature_id = fc.feature_id
 JOIN pub ON fc.pub_id = pub.pub_id
 WHERE allele_gene_rel_type.name = 'instance_of'
   AND allele_genotype_rel_type.name = 'part_of'
   AND gene_type.name = 'gene'
 UNION
 SELECT sub.uniquename AS gene_uniquename,
        'FR:' || r.feature_relationship_id AS id, pub.uniquename AS pmid,
   (SELECT value FROM organismprop p WHERE p.organism_id = organism.organism_id) AS taxonid,
   (SELECT flag FROM pub_community_curated_flags fl WHERE fl.pub_id = pub.pub_id) as publication_community_curated,
   (SELECT distinct(value)
    FROM feature_relationshipprop date_prop
    WHERE r.feature_relationship_id = date_prop.feature_relationship_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) AS annotation_date,
   substring((SELECT distinct(value)
    FROM feature_relationshipprop date_prop
    WHERE r.feature_relationship_id = date_prop.feature_relationship_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) FROM E'^(\\d\\d\\d\\d)')::integer AS annotation_year,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) AS session,
   array_to_string(array (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'curator_name')), ',') AS curator_name,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'community_curated') limit 1)::boolean AS community_curated,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'annotation_throughput_type') limit 1) AS annotation_throughput_type,
   NULL,
   (SELECT distinct(value)
    FROM feature_relationshipprop source_database_prop
    WHERE r.feature_relationship_id = source_database_prop.feature_relationship_id
      AND source_database_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_database')) AS annotation_source,
   (SELECT distinct(value)
    FROM feature_relationshipprop source_file_prop
    WHERE r.feature_relationship_id = source_file_prop.feature_relationship_id
      AND source_file_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_file')) AS source_file,
    rel_type.name AS annotation_type
 FROM feature_relationship r
 JOIN cvterm rel_type ON r.type_id = rel_type.cvterm_id
 JOIN feature sub ON r.subject_id = sub.feature_id
 JOIN organism ON sub.organism_id = organism.organism_id
 JOIN cvterm ft ON sub.type_id = ft.cvterm_id
 JOIN feature_relationship_pub frp ON frp.feature_relationship_id = r.feature_relationship_id
 JOIN pub ON frp.pub_id = pub.pub_id
 WHERE ft.name = 'gene'
   AND (rel_type.name = 'interacts_genetically'
        OR rel_type.name = 'interacts_physically'
        OR rel_type.name = 'orthologous_to')
 UNION
 SELECT obj.uniquename AS gene_uniquename,
        'FR:' || r.feature_relationship_id AS id, pub.uniquename AS pmid,
   (SELECT value FROM organismprop p WHERE p.organism_id = organism.organism_id) AS taxonid,
   (SELECT flag FROM pub_community_curated_flags fl WHERE fl.pub_id = pub.pub_id) as publication_community_curated,
   (SELECT distinct(value)
    FROM feature_relationshipprop date_prop
    WHERE r.feature_relationship_id = date_prop.feature_relationship_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) AS annotation_date,
   substring((SELECT distinct(value)
    FROM feature_relationshipprop date_prop
    WHERE r.feature_relationship_id = date_prop.feature_relationship_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) FROM E'^(\\d\\d\\d\\d)')::integer AS annotation_year,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) AS session,
   array_to_string(array (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'curator_name')), ',') AS curator_name,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'community_curated') limit 1)::boolean AS community_curated,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'annotation_throughput_type') limit 1) AS annotation_throughput_type,
   NULL,
   (SELECT distinct(value)
    FROM feature_relationshipprop source_database_prop
    WHERE r.feature_relationship_id = source_database_prop.feature_relationship_id
      AND source_database_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_database')) AS annotation_source,
   (SELECT distinct(value)
    FROM feature_relationshipprop source_file_prop
    WHERE r.feature_relationship_id = source_file_prop.feature_relationship_id
      AND source_file_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_file')) AS source_file,
   rel_type.name AS annotation_type
 FROM feature_relationship r
 JOIN cvterm rel_type ON r.type_id = rel_type.cvterm_id
 JOIN feature obj ON r.object_id = obj.feature_id
 JOIN organism ON obj.organism_id = organism.organism_id
 JOIN cvterm ft ON obj.type_id = ft.cvterm_id
 JOIN feature_relationship_pub frp ON frp.feature_relationship_id = r.feature_relationship_id
 JOIN pub ON frp.pub_id = pub.pub_id
 WHERE ft.name = 'gene'
   AND (rel_type.name = 'interacts_genetically'
        OR rel_type.name = 'interacts_physically'
        OR rel_type.name = 'orthologous_to')
UNION
  SELECT gene.uniquename AS gene_uniquename,
   'FT:' || genotype_interaction.feature_id AS id, pub.uniquename AS pmid,
   (SELECT value FROM organismprop p WHERE p.organism_id = organism.organism_id) AS taxonid,
   (SELECT flag FROM pub_community_curated_flags fl WHERE fl.pub_id = pub.pub_id) as publication_community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) AS annotation_date,
   substring((SELECT distinct(value)
    FROM feature_cvtermprop date_prop
    WHERE fc.feature_cvterm_id = date_prop.feature_cvterm_id
      AND date_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'date')) FROM E'^(\\d\\d\\d\\d)')::integer AS annotation_year,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) AS session,
   array_to_string(array (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'curator_name')), ',') AS curator_name,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'community_curated'))::boolean AS community_curated,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'annotation_throughput_type') limit 1) AS annotation_throughput_type,
   (SELECT distinct(value)
    FROM feature_cvtermprop evidence_prop
    WHERE fc.feature_cvterm_id = evidence_prop.feature_cvterm_id
      AND evidence_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'evidence')) AS evidence_code,
   (SELECT distinct(value)
    FROM feature_cvtermprop assigned_by_prop
    WHERE fc.feature_cvterm_id = assigned_by_prop.feature_cvterm_id
      AND assigned_by_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'assigned_by')) AS annotation_source,
   (SELECT distinct(value)
    FROM feature_cvtermprop source_file_prop
    WHERE fc.feature_cvterm_id = source_file_prop.feature_cvterm_id
      AND source_file_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'source_file')) AS source_file,
   'interacts_genetically' AS annotation_type
 FROM feature gene
 JOIN organism ON gene.organism_id = organism.organism_id
 JOIN cvterm gene_type ON gene_type.cvterm_id = gene.type_id
 JOIN feature_relationship allele_gene_rel ON allele_gene_rel.object_id = gene.feature_id
 JOIN feature allele ON allele.feature_id = allele_gene_rel.subject_id
 JOIN cvterm allele_gene_rel_type ON allele_gene_rel.type_id = allele_gene_rel_type.cvterm_id
 JOIN feature_relationship allele_genotype_rel ON allele_genotype_rel.subject_id = allele.feature_id
 JOIN feature genotype ON allele_genotype_rel.object_id = genotype.feature_id
 JOIN cvterm allele_genotype_rel_type ON allele_genotype_rel.type_id = allele_genotype_rel_type.cvterm_id
 JOIN feature_relationship genotype_interaction_rel ON genotype_interaction_rel.subject_id = genotype.feature_id
 JOIN cvterm genotype_interaction_rel_type ON genotype_interaction_rel.type_id = genotype_interaction_rel_type.cvterm_id
 JOIN feature genotype_interaction ON genotype_interaction_rel.object_id = genotype_interaction.feature_id
 JOIN cvterm genotype_interaction_type ON genotype_interaction_type.cvterm_id = genotype_interaction.type_id
 JOIN pombase_feature_cvterm_ext_resolved_terms fc ON genotype_interaction.feature_id = fc.feature_id
 JOIN pub ON fc.pub_id = pub.pub_id
WHERE allele_gene_rel_type.name = 'instance_of'
AND allele_genotype_rel_type.name = 'part_of'
AND gene_type.name = 'gene'
AND genotype_interaction_type.name = 'genotype_interaction'
AND (genotype_interaction_rel_type.name = 'interaction_genotype_a'
  OR genotype_interaction_rel_type.name = 'interaction_genotype_b');
EOF

psql -q $DB -c "CREATE MATERIALIZED VIEW pombase_annotation_summary AS
SELECT distinct id, pmid, taxonid, publication_community_curated, annotation_date,
       annotation_year, session, curator_name, community_curated, annotation_throughput_type,
       evidence_code, annotation_source, source_file, annotation_type
  FROM pombase_genes_annotations_dates;"

psql -q $DB -c "CREATE MATERIALIZED VIEW pombase_annotated_gene_features_per_publication AS
SELECT gene.uniquename AS gene_uniquename, pub.uniquename AS pmid,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) as session
   FROM feature gene
   JOIN cvterm gene_type ON gene_type.cvterm_id = gene.type_id
   JOIN feature_relationship r ON r.object_id = gene.feature_id
   JOIN cvterm t ON r.type_id = t.cvterm_id
   JOIN feature mrna ON mrna.feature_id = subject_id
   JOIN cvterm rna_type ON rna_type.cvterm_id = mrna.type_id
   JOIN feature_cvterm fc ON mrna.feature_id = fc.feature_id
   JOIN pub ON fc.pub_id = pub.pub_id
   WHERE t.name = 'part_of'
     AND gene_type.name = 'gene'
     AND rna_type.name like '%RNA'
UNION
 SELECT gene.uniquename AS gene_uniquename, pub.uniquename AS pmid,
   (SELECT distinct(value)
    FROM feature_cvtermprop session_prop
    WHERE fc.feature_cvterm_id = session_prop.feature_cvterm_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) as session
   FROM feature gene
   JOIN cvterm gene_type ON gene_type.cvterm_id = gene.type_id
   JOIN feature_relationship allele_gene_rel ON allele_gene_rel.object_id = gene.feature_id
   JOIN feature allele ON allele.feature_id = allele_gene_rel.subject_id
   JOIN cvterm allele_gene_rel_type ON allele_gene_rel.type_id = allele_gene_rel_type.cvterm_id
   JOIN feature_relationship allele_genotype_rel ON allele_genotype_rel.subject_id = allele.feature_id
   JOIN feature genotype ON allele_genotype_rel.object_id = genotype.feature_id
   JOIN cvterm allele_genotype_rel_type ON allele_genotype_rel.type_id = allele_genotype_rel_type.cvterm_id
   JOIN feature_cvterm fc ON genotype.feature_id = fc.feature_id
   JOIN pub ON fc.pub_id = pub.pub_id
   WHERE allele_gene_rel_type.name = 'instance_of'
     AND allele_genotype_rel_type.name = 'part_of'
     AND gene_type.name = 'gene'
UNION
 SELECT sub.uniquename AS gene_uniquename, pub.uniquename AS pmid,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) as session
   FROM feature_relationship r
   JOIN cvterm rel_type ON r.type_id = rel_type.cvterm_id
   JOIN feature sub ON r.subject_id = sub.feature_id
   JOIN cvterm ft ON sub.type_id = ft.cvterm_id
   JOIN feature_relationship_pub frp ON frp.feature_relationship_id = r.feature_relationship_id
   JOIN pub ON frp.pub_id = pub.pub_id
   WHERE ft.name = 'gene'
     AND (rel_type.name = 'interacts_genetically'
          OR rel_type.name = 'interacts_physically')
UNION
 SELECT obj.uniquename AS gene_uniquename, pub.uniquename AS pmid,
   (SELECT distinct(value)
    FROM feature_relationshipprop session_prop
    WHERE r.feature_relationship_id = session_prop.feature_relationship_id
      AND session_prop.type_id IN
        (SELECT cvterm_id
         FROM cvterm
         WHERE name = 'canto_session')) as session
   FROM feature_relationship r
   JOIN cvterm rel_type ON r.type_id = rel_type.cvterm_id
   JOIN feature obj ON r.object_id = obj.feature_id
   JOIN cvterm ft ON obj.type_id = ft.cvterm_id
   JOIN feature_relationship_pub frp ON frp.feature_relationship_id = r.feature_relationship_id
   JOIN pub ON frp.pub_id = pub.pub_id
   WHERE ft.name = 'gene'
     AND (rel_type.name = 'interacts_genetically'
          OR rel_type.name = 'interacts_physically');"

psql -q $DB -c "CREATE MATERIALIZED VIEW pombase_genotypes_alleles_genes_mrna AS
SELECT genotype.uniquename genotype_uniquename, genotype.feature_id as genotype_feature_id,
 allele.uniquename as allele_uniquename, allele.name as allele_name,
 allele.feature_id as allele_feature_id,
 gene.feature_id as gene_feature_id,
 gene.uniquename as gene_uniquename, gene.name as gene_name,
 mrna.feature_id as mrna_feature_id, mrna.uniquename as mrna_uniquename
FROM feature genotype
JOIN cvterm genotype_type on genotype.type_id = genotype_type.cvterm_id
JOIN feature_relationship genotype_allele_rel ON genotype_allele_rel.object_id = genotype.feature_id
JOIN cvterm genotype_allele_rel_type ON genotype_allele_rel_type.cvterm_id = genotype_allele_rel.type_id
JOIN feature allele ON genotype_allele_rel.subject_id = allele.feature_id
JOIN cvterm allele_type on allele.type_id = allele_type.cvterm_id
JOIN feature_relationship gene_genotype_rel on allele.feature_id = gene_genotype_rel.subject_id
JOIN feature gene on gene.feature_id = gene_genotype_rel.object_id
JOIN cvterm gene_type on gene.type_id = gene_type.cvterm_id
JOIN cvterm gene_genotype_rel_type on gene_genotype_rel.type_id = gene_genotype_rel_type.cvterm_id
JOIN feature_relationship gene_mrna_rel on gene.feature_id = gene_mrna_rel.object_id
JOIN cvterm gene_mrna_rel_type on gene_mrna_rel.type_id = gene_mrna_rel_type.cvterm_id
JOIN feature mrna on gene_mrna_rel.subject_id = mrna.feature_id
WHERE genotype_allele_rel_type.name = 'part_of'
  AND gene_genotype_rel_type.name = 'instance_of'
  AND gene_mrna_rel_type.name = 'part_of'
  AND genotype_type.name = 'genotype'
  AND allele_type.name = 'allele'
  AND gene_type.name = 'gene';"


psql -q $DB <<'EOF'
CREATE MATERIALIZED VIEW pombase_publication_curation_summary AS
WITH all_pubs_raw AS
  (SELECT uniquename AS pmid,
     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_session'
      LIMIT 1) AS canto_session,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_added_date'
      LIMIT 1)::TIMESTAMP AS canto_added_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_first_sent_to_curator_date'
      LIMIT 1)::TIMESTAMP AS canto_first_sent_to_curator_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_first_approved_date'
      LIMIT 1)::TIMESTAMP AS canto_first_approved_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_session_accepted_date'
      LIMIT 1)::TIMESTAMP AS canto_session_accepted_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_session_submitted_date'
      LIMIT 1)::TIMESTAMP AS canto_session_submitted_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_approved_date'
      LIMIT 1)::TIMESTAMP AS canto_approved_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_curator_name'
      LIMIT 1) AS canto_curator_name,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_triage_status'
      LIMIT 1) AS canto_triage_status,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_annotation_status'
      LIMIT 1) AS canto_annotation_status,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_curator_role'
      LIMIT 1) AS canto_curator_role,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'canto_approver_name'
      LIMIT 1) AS canto_approver_name,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'pubmed_publication_date'
      LIMIT 1) AS pubmed_publication_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'pubmed_electronic_publication_date'
      LIMIT 1)::date AS pubmed_electronic_publication_date,

     (SELECT value
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'pubmed_entrez_date'
      LIMIT 1)::date AS pubmed_entrez_date,

     (SELECT substring(value FROM E'\\d\\d\\d\\d')::integer
      FROM pubprop pp
      JOIN cvterm ppt ON pp.type_id = ppt.cvterm_id
      WHERE pp.pub_id = pub.pub_id
        AND ppt.name = 'pubmed_publication_date'
      LIMIT 1) AS pubmed_publication_year

   FROM pub WHERE uniquename LIKE 'PMID:%')
SELECT all_pubs_raw.*,
       CASE WHEN pubmed_electronic_publication_date IS NOT NULL
             AND pubmed_electronic_publication_date < pubmed_entrez_date
          THEN pubmed_electronic_publication_date
          ELSE pubmed_entrez_date
       END AS pubmed_earliest_date,
       EXTRACT (YEAR FROM canto_added_date)::integer AS canto_added_year,
       EXTRACT (YEAR FROM canto_first_sent_to_curator_date)::integer AS canto_first_sent_to_curator_year,
       EXTRACT (YEAR FROM canto_first_approved_date)::integer AS canto_first_approved_year,
       EXTRACT (YEAR FROM canto_session_accepted_date)::integer AS canto_session_accepted_year,
       EXTRACT (YEAR FROM canto_session_submitted_date)::integer AS canto_session_submitted_year,
       EXTRACT (YEAR FROM canto_approved_date)::integer AS canto_approved_year
FROM all_pubs_raw;
EOF

cd $BASE

echo initialising Chado with CVs and cvterms 
$BASE/pombase-chado/script/pombase-admin.pl $LOAD_CONFIG chado-init \
  "$HOST" $DB $USER $PASSWORD || exit 1


echo loading organisms
$BASE/pombase-chado/script/pombase-import.pl $LOAD_CONFIG organisms \
    "$HOST" $DB $USER $PASSWORD < $GIT_DIR/organism_config.tsv

#echo loading PB refs
$BASE/pombase-chado/script/pombase-import.pl $LOAD_CONFIG references-file \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/PB_references.txt

echo loading GO refs parsed from go-site/metadata/gorefs/
$BASE/pombase-chado/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml references-file \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/go_references.txt


cd $LOG_DIR
log_file=log.`date +'%Y-%m-%d-%H-%M-%S'`
$POMBASE_LEGACY/script/load-chado.pl --taxonid=7227 \
  --gene-ex-qualifiers $GIT_DIR/gene_ex_qualifiers \
  $LOAD_CONFIG $BUILD_ID \
  "$HOST" $DB $USER $PASSWORD $GIT_DIR/contigs/*.contig 2>&1 | tee $log_file || exit 1


$POMBASE_LEGACY/etc/process-log.pl $log_file

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'

echo loading names_and_products.tsv
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG names-and-products \
    --dest-organism-taxonid=7227 \
    "$HOST" $DB $USER $PASSWORD < $GIT_DIR/names_and_products.tsv


echo loading systematic_id_uniprot_mapping.tsv
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG generic-property \
    --property-name="uniprot_identifier" --organism-taxonid=7227 \
    --feature-uniquename-column=1 --property-column=2 \
    "$HOST" $DB $USER $PASSWORD < $GIT_DIR/systematic_id_uniprot_mapping.tsv

evidence_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'evidence') group by value order by count(feature_cvtermprop_id)" | cat
}

assigned_by_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'assigned_by') group by value order by count(feature_cvtermprop_id);" | cat
}

refresh_views () {
  for view in \
    pombase_annotated_gene_features_per_publication \
    pombase_feature_cvterm_with_ext_parents \
    pombase_feature_cvterm_no_ext_terms \
    pombase_feature_cvterm_ext_resolved_terms \
    pombase_genotypes_alleles_genes_mrna \
    pombase_extension_rels_and_values \
    pombase_genes_annotations_dates \
    pombase_annotation_summary \
    pombase_publication_curation_summary
  do
    psql $DB -c "REFRESH MATERIALIZED VIEW $view;"
  done
}

echo annotation evidence counts before loading
evidence_summary $DB


CURRENT_GOA_GAF=$SOURCES/gene_association.goa_uniprot.gz
GOA_POMBE_AND_JAPONICUS="$SOURCES/gene_association.goa_uniprot.pombe+japonicus.gz"
GOA_VERSION=`cat $GOA_POMBE_AND_JAPONICUS.uniprot_version`

$POMBASE_CHADO/script/pombase-admin.pl $LOAD_CONFIG add-chado-prop \
  "$HOST" $DB $USER $PASSWORD "UniProt-GOA_version" $GOA_VERSION

echo reading $GOA_POMBE_AND_JAPONICUS
gzip -d < $GOA_POMBE_AND_JAPONICUS | perl -ne 'print if /\ttaxon:7227\t/' |
    $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
       --taxon-filter=7227 --use-only-first-with-id \
       --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs \
       --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings \
       --assigned-by-filter=GOC,RNAcentral,InterPro,UniProtKB,UniProt "$HOST" $DB $USER $PASSWORD \
       2>&1 | tee $LOG_DIR/$log_file.goa_gene_association_japonicus

gzip -d < $GOA_POMBE_AND_JAPONICUS | perl -ne 'print if /\ttaxon:7227\t/' |
    $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
       --taxon-filter=7227 \
       --with-prefix-filter="PANTHER:" \
       --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs \
       --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings \
       --assigned-by-filter=GO_Central "$HOST" $DB $USER $PASSWORD \
       2>&1 | tee $LOG_DIR/$log_file.goa_gene_association_panther_japonicus


echo annotation count after GAF loading:
evidence_summary $DB


PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'

refresh_views

$BASE/pombase-chado/script/pombase-process.pl \
    $LOAD_CONFIG add-reciprocal-ipi-annotations \
    --organism-taxonid=7227 "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.add_reciprocal_ipi_annotations

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

echo
echo counts of assigned_by before filtering:
assigned_by_summary $DB

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'

echo
echo filtering redundant annotations - `date`
$BASE/pombase-chado/script/pombase-process.pl $LOAD_CONFIG go-filter "$HOST" $DB $USER $PASSWORD
echo done GO filtering - `date`


echo
echo filtering redundant annotations - `date`
$BASE/pombase-chado/script/pombase-process.pl $LOAD_CONFIG go-filter-with-not "$HOST" $DB $USER $PASSWORD
echo done filtering using NOT annotations - `date`


echo
echo counts of assigned_by after filtering:
assigned_by_summary $DB

echo
echo annotation count after filtering redundant GO annotations
evidence_summary $DB

echo
echo query PubMed for publication details, then store
$POMBASE_CHADO/script/pubmed_util.pl $LOAD_CONFIG \
  "$HOST" $DB $USER $PASSWORD --add-missing-fields \
  --organism-taxonid=7227 2>&1 | tee $LOG_DIR/$log_file.pubmed_query


echo
echo loading finished


PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

mkdir -p $CURRENT_BUILD_DIR
mkdir -p $CURRENT_BUILD_DIR/logs
mkdir -p $CURRENT_BUILD_DIR/exports
mkdir -p $CURRENT_BUILD_DIR/pombe-embl/supporting_files


cp $LOG_DIR/$log_file.* $CURRENT_BUILD_DIR/logs/



echo creating files for the website:
$POMCUR/bin/pombase-chado-json -c $MAIN_CONFIG \
   --doc-config-file $BASE/pombase-website/src/app/config/doc-config.json \
   -p "postgres://$USER:$PASSWORD@localhost/$DB" \
   -d $CURRENT_BUILD_DIR/ --go-eco-mapping=$SOURCES/gaf-eco-mapping.txt \
   --filter-uniprot-references=PMID:18257517 \
   2>&1 | tee $LOG_DIR/$log_file.web-json-write

find $CURRENT_BUILD_DIR/fasta -name '*.fa' | xargs gzip -9f

cp $LOG_DIR/$log_file.web-json-write $CURRENT_BUILD_DIR/logs/

DB_BASE_NAME=`echo $DB | sed 's/-v[0-9]$//'`

zstd -9q --rm $CURRENT_BUILD_DIR/api_maps.sqlite3

cp $LOG_DIR/*.txt $CURRENT_BUILD_DIR/logs/

cp $SOURCES/pombe-embl/supporting_files/PB_references.txt \
   $CURRENT_BUILD_DIR/pombe-embl/supporting_files/

psql $DB -c 'grant select on all tables in schema public to public;'

DUMP_FILE=$CURRENT_BUILD_DIR/$DB.chado_dump.gz

echo dumping to $DUMP_FILE
pg_dump $DB | gzip -2 > $DUMP_FILE

rm -f $DUMPS_DIR/latest_build
ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/latest_build

(cd $BASE/container_build
 (cd pombase-fly-query && git pull)
 cp -f pombase-fly-query/site_config.json main_config.json
 nice -10 $GIT_DIR/build_container.sh $BUILD_ID $DUMPS_DIR/latest_build)

IMAGE_NAME=fly-query/web:$BUILD_ID-prod

# temporarily add another replica so so have no downtime when we update
#docker service update --replicas 2 japonicus-1
#sleep 60
#docker service update --update-delay 0s --image=$IMAGE_NAME japonicus-1
#sleep 60
#docker service update --replicas 1 japonicus-1

echo finished building: $DB

date

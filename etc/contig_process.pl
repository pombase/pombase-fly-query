#!/usr/bin/perl

my $current = undef;
my $seen_qual = 0;
my $seen_ac = 0;
my $in_qual = 0;

while (<>) {
  if (/^(ID|AC|FT|FH|SQ|\/\/|  )/) {
    if ($1 eq 'AC') {
      if ($seen_ac) {
        next;
      } else {
        $seen_ac = 1;
        s/;.*/;/;
      }
    }
    if (/^FT/) {
      if (/^FT   (\S+)/) {
        $current = $1;
        $seen_qual = 0;
      } else {
        if (m|FT                   /|) {
          $seen_qual = 1;
        }
      }

      if ($current eq 'CDS') {
        if ($seen_qual) {
          if (/^(FT\s+\/)(gene|gene_synonym|locus_tag|product|protein_id)=(.*)/) {
            $in_qual = 1;
            my $q_name = $2;
            if ($q_name eq 'gene') {
              $q_name = 'primary_name';
            } else {
              if ($q_name eq 'gene_synonym') {
                $q_name = 'synonym';
              } else {
                if ($q_name eq 'locus_tag') {
                  $q_name = 'systematic_id';
                }
              }
            }
            my $q_value = $3;
            print "$1$q_name=$q_value\n";

            if ($q_value =~ /"$/) {
              $in_qual = 0;
            }
          } else {
            if ($in_qual) {
              print;
              if (/"$/) {
                $in_qual = 0;
              }
            }
          }
        } else {
          print;
        }
      }
    } else{
      print;
    }
  }
}

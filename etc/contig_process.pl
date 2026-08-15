#!/usr/bin/perl

my $current = undef;
my $seen_qual = 0;
my $seen_ac = 0;
my $in_qual = 0;

my %id_map = ();

open my $map_fh, '<', shift or die;
while (defined (my $line = <$map_fh>)) {
  chomp $line;
  my ($id, $fb_id) = split /\t/, $line;
  $id_map{$id} = $fb_id;
}
close $map_fh;

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
            my $start = $1;
            my $q_name = $2;
            my $q_value = $3;
            if ($q_name eq 'gene') {
              $q_name = 'primary_name';
            } else {
              if ($q_name eq 'gene_synonym') {
                $q_name = 'synonym';
              } else {
                if ($q_name eq 'locus_tag') {
                  $q_name = 'systematic_id';
                  if ($q_value =~ /Dmel_(.*)"/) {
                    my $new_val = $id_map{$1};
                    if ($new_val) {
                      $q_value = qq|"$new_val"|;
                    } else {
                      die "can't find: $1\n";
                    }
                  }
                }
              }
            }
            print "$start$q_name=$q_value\n";

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

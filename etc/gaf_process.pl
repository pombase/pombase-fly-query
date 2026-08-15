#!/usr/bin/perl

my %id_map = ();

open my $map_fh, '<', shift or die;
while (defined (my $line = <$map_fh>)) {
  chomp $line;
  my ($id, $fb_id) = split /\t/, $line;
  $id_map{$id} = $fb_id;
}
close $map_fh;


open my $gaf, '-|', 'gzip -d < /var/pomcur/sources/gene_association.goa_uniprot.pombe+japonicus.gz'
  or die;

while (defined (my $line = <$gaf>)) {
  chomp $line;
  my @bits = split /\t/, $line;

  next if $bits[12] ne 'taxon:7227';

  my @synonyms = split /\|/, $bits[10];

  map {
    my $syn = $_;

    if (exists $id_map{$syn}) {
      $bits[10] .= '|' . $id_map{$syn};
    }
  } @synonyms;

  my $line = join "\t", @bits;

  print "$line\n";
}


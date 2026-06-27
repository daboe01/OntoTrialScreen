#!/usr/bin/perl
use strict;
use warnings;
use Mojo::File;
use DBI;
use SQL::Abstract;

my $text = Mojo::File->new('/Users/Shared/bin/OntoMan/hp.obo')->slurp;

# Connect to database (AutoCommit is temporarily left on for the DELETE statements)
my $dbh = DBI->connect(
                       'dbi:Pg:dbname=hpo;host=aug-info-db',
                       'postgres',
                       'postgres',
                       { pg_enable_utf8 => 1, AutoCommit => 1, RaiseError => 1 }
);
my $sql = SQL::Abstract->new();

print "Cleaning existing database tables to start with a blank sheet...\n";
# Delete child tables first to avoid foreign key constraint violations
$dbh->do('DELETE FROM isas');
$dbh->do('DELETE FROM xrefs');
$dbh->do('DELETE FROM synonyms');
# Delete main terms table last
$dbh->do('DELETE FROM terms');
print "Database cleaned. Starting import...\n";

# Helper Subs
sub catchSynonyms{
    my ($dbh, $id, $syn) = @_;
    my($stmt, @bind) = $sql->insert('synonyms', { idterm => $id, label => $syn });
    $dbh->do($stmt, undef, @bind);
}

sub catchXREFs{
    my ($dbh, $id, $xref) = @_;
    my($stmt, @bind) = $sql->insert('xrefs', { idterm => $id, label => $xref });
    $dbh->do($stmt, undef, @bind);
}

sub catchISAs{
    my ($dbh, $idchild, $idparent) = @_;
    my($stmt, @bind) = $sql->insert('isas', { idchild => $idchild, idparent => $idparent });
    $dbh->do($stmt, undef, @bind);
}

my @terms = split /\[Term\]/, $text;
shift @terms; # cut header off

# Begin a transaction. This speeds up bulk inserts in Postgres immensely.
$dbh->begin_work;

foreach my $term (@terms)
{
    # Use ^ and /m to ensure we only match at the start of a line
    my ($id) = $term =~ /^id:\s*HP:(.+)/m;
    next unless defined $id; # Skip safely if it's a malformed block

    # Extract single-value attributes
    my ($name)    = $term =~ /^name:\s*(.+)/m;
    my ($comment) = $term =~ /^comment:\s*(.+)/m;

    # Extract definition safely.
    # (.*?) matches lazily up to the closing quote just before the reference brackets [ ]
    my ($def)     = $term =~ /^def:\s*"(.*?)"\s*\[/m;

    # Insert main term. SQL::Abstract automatically handles 'undef' by inserting NULL.
    my($stmt, @bind) = $sql->insert('terms', {
        id         => $id,
        label      => $name,
        definition => $def,
        comment    => $comment
    });
    $dbh->do($stmt, undef, @bind);

    # Extract Synonyms
    while ($term =~ /^synonym:\s*"([^"]+)"/mg) {
        catchSynonyms($dbh, $id, $1);
}

# Extract XREFs
while ($term =~ /^xref:\s*([^\r\n]+)/mg) {
    my $xref = $1;

    # Extra safety check: Ignore lines that might have been accidentally prefixed
    next if $xref =~ /^(property_value|created_by|terms:|dc:|IAO:|owl:)/i;

    catchXREFs($dbh, $id, $xref);
}

# Extract ISAs
while ($term =~ /^is_a:\s*HP:([0-9]+)/mg) {
    catchISAs($dbh, $id, $1);
}
}

# Commit all the database inserts at once
$dbh->commit;

print "Finished processing HPO OBO file.\n";

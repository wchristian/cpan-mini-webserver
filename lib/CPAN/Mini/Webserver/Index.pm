package CPAN::Mini::Webserver::Index;
use Moose;
use List::MoreUtils qw(uniq);
use Search::QueryParser;
use String::CamelCase qw(wordsplit);
use Text::Unidecode;

has 'index' => ( is => 'rw', isa => 'HashRef', default => sub { {} } );

sub add {
    my ( $self, $key, $words ) = @_;
    my $index = $self->index;
    push @{ $index->{$_} }, $key for @{$words};
}

sub create_index {
    my ( $self, $parse_cpan_authors, $parse_cpan_packages ) = @_;

    for my $author ( $parse_cpan_authors->authors ) {
        my @words = split ' ', unidecode lc $author->name;
        push @words, lc $author->pauseid;
        $self->add( $author, \@words );
    }

    for my $distribution ( $parse_cpan_packages->latest_distributions ) {
        my @words;
        for my $word ( split '-', unidecode $distribution->dist ) {
            push @words, $word;
            push @words, wordsplit $word;
        }
        @words = map { lc } uniq @words;

        $self->add( $distribution, \@words );
    }

    for my $package ( $parse_cpan_packages->packages ) {
        my @words;
        for my $word ( split '::', unidecode $package->package ) {
            push @words, $word;
            push @words, wordsplit $word;
        }
        @words = map { lc } uniq @words;
        $self->add( $package, \@words );
    }

}

sub search {
    my ( $self, $q ) = @_;
    my $index = $self->index;
    my @results;

    my $qp = Search::QueryParser->new( rxField => qr/NOTAFIELD/, );
    my $query = $qp->parse( $q, 1 );
    unless ( $query ) {

        # warn "Error in query : " . $qp->err;
        return;
    }

    for my $part ( @{ $query->{'+'} } ) {
        my $value = $part->{value};
        my @words = split /(?:\:\:| |-)/, unidecode lc $value;
        for my $word ( @words ) {
            my @word_results = @{ $index->{$word} || [] };
            if ( @results ) {
                my %seen;
                $seen{$_} = 1 for @word_results;
                @results = grep { $seen{$_} } @results;
            }
            else {
                @results = @word_results;
            }
        }
    }

    for my $part ( @{ $query->{'-'} } ) {
        my $value        = $part->{value};
        my @word_results = $self->search_word( $value );
        my %seen;
        $seen{$_} = 1 for @word_results;
        @results = grep { !$seen{$_} } @results;
    }

    return @results;
}

sub search_word {
    my ( $self, $word ) = @_;
    my $index = $self->index;
    my @words = split /(?:\:\:| |-)/, unidecode lc $word;
    @words = grep exists( $index->{$_} ), @words;

    my @results = map @{ $index->{$_} }, @words;
    return @results;
}

1;

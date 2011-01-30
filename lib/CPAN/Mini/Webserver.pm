package CPAN::Mini::Webserver;
use App::Cache;
use Archive::Peek;
use CPAN::Mini::App;
use CPAN::Mini::Webserver::Index;
use CPAN::Mini::Webserver::Templates;
use CPAN::Mini::Webserver::Templates::CSS;
use CPAN::Mini::Webserver::Templates::Images;
use Encode;
use File::Spec::Functions qw( canonpath catfile );
use File::Type;
use List::MoreUtils qw(uniq);
use Module::InstalledVersion;
use Moose;
use Parse::CPAN::Authors;
use Parse::CPAN::Packages;
use Parse::CPAN::Whois;
use Parse::CPAN::Meta;
use Pod::Simple::HTML;
use Path::Class;
use PPI;
use PPI::HTML;
use Safe;
use Template::Declare;
use Try::Tiny;

Template::Declare->init( roots => [ 'CPAN::Mini::Webserver::Templates', 'CPAN::Mini::Webserver::Templates::CSS', 'CPAN::Mini::Webserver::Templates::Images', ] );

if ( eval { require HTTP::Server::Simple::Bonjour } ) {
    extends 'HTTP::Server::Simple::Bonjour', 'HTTP::Server::Simple::CGI';
}
else {
    extends 'HTTP::Server::Simple::CGI';
}

has 'hostname'            => ( is => 'rw' );
has 'cgi'                 => ( is => 'rw', isa => 'CGI' );
has 'directory'           => ( is => 'rw', isa => 'Path::Class::Dir' );
has 'scratch'             => ( is => 'rw', isa => 'Path::Class::Dir' );
has 'author_type'         => ( is => 'rw' );
has 'parse_cpan_authors'  => ( is => 'rw' );
has 'parse_cpan_packages' => ( is => 'rw', isa => 'Parse::CPAN::Packages' );
has 'pauseid'             => ( is => 'rw' );
has 'distvname'           => ( is => 'rw' );
has 'filename'            => ( is => 'rw' );
has 'index'               => ( is => 'rw', isa => 'CPAN::Mini::Webserver::Index' );

our $VERSION = '0.51';

sub service_name {
    "$ENV{USER}'s minicpan_webserver";
}

sub get_file_from_tarball {
    my ( $self, $distribution, $filename ) = @_;

    my $file = file( $self->directory, 'authors', 'id', $distribution->prefix );
    my $peek = Archive::Peek->new( filename => $file );
    my $contents = $peek->file( $filename );
    return $contents;
}

sub checksum_data_for_author {
    my ( $self, $pauseid ) = @_;

    my $file = file( $self->directory, 'authors', 'id', substr( $pauseid, 0, 1 ), substr( $pauseid, 0, 2 ), $pauseid, 'CHECKSUMS', );

    return unless -f $file;

    my ( $content );
    {
        local $/;
        open my $fh, "$file" or die "$file: $!";
        $content = <$fh>;
        close $fh;
    }

    my $compmt = Safe->new;
    my $chksum = $compmt->reval( $content );

    return $chksum;
}

sub send_http_header {
    my $self   = shift;
    my $code   = shift;
    my %params = @_;
    my $cgi    = $self->cgi;

    if (   ( defined $params{-charset} and $params{-charset} eq 'utf-8' )
        or ( defined $params{-type} and $params{-type} eq 'text/xml' ) )
    {
        binmode( STDOUT, ":encoding(utf-8)" );
    }
    elsif ( defined $params{-type} ) {
        binmode STDOUT, ":raw";
    }
    print "HTTP/1.0 $code\015\012";
    print $cgi->header( %params );
}

# this is a hook that HTTP::Server::Simple calls after setting up the
# listening socket. we use it load the indexes
sub after_setup_listener {
    my ( $self, $cache_dir ) = @_;

    my %config    = CPAN::Mini->read_config;
    my $directory = dir( glob $config{local} );
    $self->directory( $directory );
    my $authors_filename  = file( $directory, 'authors', '01mailrc.txt.gz' );
    my $packages_filename = file( $directory, 'modules', '02packages.details.txt.gz' );
    die "Please set up minicpan"
      unless defined( $directory )
          && ( -d $directory )
          && ( -f $authors_filename )
          && ( -f $packages_filename );

    my %cache_opts = ( ttl => 60 * 60 );
    $cache_opts{directory} = $cache_dir if $cache_dir;
    my $cache = App::Cache->new( \%cache_opts );

    my $whois_filename = file( $directory, 'authors', '00whois.xml' );
    my $parse_cpan_authors;
    if ( -f $whois_filename ) {
        $self->author_type( 'Whois' );
        $parse_cpan_authors = $cache->get_code( 'parse_cpan_whois', sub { Parse::CPAN::Whois->new( $whois_filename->stringify ) } );
    }
    else {
        $self->author_type( 'Authors' );
        $parse_cpan_authors = $cache->get_code( 'parse_cpan_authors', sub { Parse::CPAN::Authors->new( $authors_filename->stringify ) } );
    }
    my $parse_cpan_packages = $cache->get_code( 'parse_cpan_packages', sub { Parse::CPAN::Packages->new( $packages_filename->stringify ) } );

    $self->parse_cpan_authors( $parse_cpan_authors );
    $self->parse_cpan_packages( $parse_cpan_packages );

    my $scratch = dir( $cache->scratch );
    $self->scratch( $scratch );

    my $index = CPAN::Mini::Webserver::Index->new;
    $self->index( $index );
    $index->create_index( $parse_cpan_authors, $parse_cpan_packages );
}

sub handle_request {
    my ( $self, $cgi ) = @_;

    my $result = try {
        $self->_handle_request( $cgi );
    }
    catch {
        $self->send_http_header( 500 );
        return "<h1>Internal Server Error</h1>", $cgi->escapeHTML( $_ );
    };
    print $result;

    return;
}

sub _handle_request {
    my ( $self, $cgi ) = @_;
    $self->cgi( $cgi );
    $self->hostname( $cgi->virtual_host() );
    my $path = $cgi->path_info;

    # $raw, $download and $install should become $action?
    my ( $raw, $install, $download, $pauseid, $distvname, $filename, $prefix );
    if ( $path =~ m{^/~} ) {
        ( undef, $pauseid, $distvname, $filename ) = split( '/', $path, 4 );
        $pauseid =~ s{^~}{};
    }
    elsif ( $path =~ m{^/(raw|download|install)/~} ) {
        ( undef, undef, $pauseid, $distvname, $filename ) = split( '/', $path, 5 );

        (
              $1 eq 'raw'     ? $raw
            : $1 eq 'install' ? $install
            : $download
        ) = 1;
        $pauseid =~ s{^~}{};
    }
    elsif ( $path =~ m{^/((?:modules|authors)/.+$)} ) {
        $prefix = $1;
    }
    $self->pauseid( $pauseid );
    $self->distvname( $distvname );
    $self->filename( $filename );

    return $self->dispatch( $path, $raw, $pauseid, $distvname, $filename, $install, $download, $prefix );
}

sub dispatch {
    my ( $self, $path, $raw, $pauseid, $distvname, $filename, $install, $download, $prefix ) = @_;

    return $self->index_page  if $path eq '/';
    return $self->search_page if $path eq '/search/';

    return $self->dispatch_by_author_id( $distvname, $raw, $filename, $install, $download ) if $pauseid;

    return $self->pod_page     if $path =~ m{^/perldoc};
    return $self->dist_page    if $path =~ m{^/dist/};
    return $self->package_page if $path =~ m{^/package/};

    return $self->download_cpan( $prefix ) if $prefix;

    my @template_type_info = $self->get_template_type_info( $path );
    return $self->direct_to_template( @template_type_info ) if @template_type_info;

    my ( $q ) = $path =~ m'/(.*?)/?$';
    return $self->not_found_page( $q );
}

sub dispatch_by_author_id {
    my ( $self, $distvname, $raw, $filename, $install, $download ) = @_;

    return $self->author_page if !$distvname;

    return $self->raw_page     if $filename and $raw;
    return $self->install_page if $filename and $install;
    return $self->download_file if $download;
    return $self->file_page     if $filename;

    return $self->distribution_page;
}

sub get_template_type_info {
    my ( $self, $path ) = @_;
    return ( "css_screen",     "text/css" )                              if $path eq '/static/css/screen.css';
    return ( "css_print",      "text/css" )                              if $path eq '/static/css/print.css';
    return ( "css_ie",         "text/css" )                              if $path eq '/static/css/ie.css';
    return ( "images_logo",    "image/png" )                             if $path eq '/static/images/logo.png';
    return ( "images_favicon", "image/png" )                             if $path eq '/static/images/favicon.png';
    return ( "images_favicon", "image/png" )                             if $path eq '/favicon.ico';
    return ( "opensearch",     "application/opensearchdescription+xml" ) if $path eq '/static/xml/opensearch.xml';
    return;
}

sub index_page {
    my $self = shift;
    $self->send_http_header( 200, -charset => 'utf-8' );
    return Template::Declare->show(
        'index',
        {
            recents            => $self->get_recent_dists,
            parse_cpan_authors => $self->parse_cpan_authors,
        }
    );
}

sub get_recent_dists {
    my ( $self ) = @_;

    my $recent_filename = catfile( $self->directory, 'RECENT' );
    return { count => 0 } if !-f $recent_filename;

    my $fh = IO::File->new( $recent_filename ) || die $!;
    my @recent = <$fh>;
    @recent = grep m{authors/id/}, @recent;

    my $recent_count = @recent;
    @recent = @recent[ 0 .. 19 ] if $recent_count > 20;
    @recent = map CPAN::DistnameInfo->new( $_ ), @recent;

    return { count => $recent_count, display_list => \@recent };
}

# TODO: not tested properly
sub not_found_page {
    my $self = shift;
    my $q    = shift;
    my ( $authors, $dists, $packages ) = $self->_do_search( $q );
    $self->send_http_header( 404, -charset => 'utf-8' );
    return Template::Declare->show(
        '404',
        {
            parse_cpan_authors => $self->parse_cpan_authors,
            q                  => $q,
            authors            => $authors,
            distributions      => $dists,
            packages           => $packages
        }
    );
}

sub redirect {
    my ( $self, $url ) = @_;
    return "HTTP/1.0 302\015\012" . $self->cgi->redirect( $url );
}

sub search_page {
    my $self = shift;
    my $q    = $self->cgi->param( 'q' );
    Encode::_utf8_on( $q );    # we know that we have sent utf-8

    my ( $authors, $dists, $packages ) = $self->_do_search( $q );
    $self->send_http_header( 200, -charset => 'utf-8' );
    return Template::Declare->show(
        'search',
        {
            parse_cpan_authors => $self->parse_cpan_authors,
            q                  => $q,
            authors            => $authors,
            distributions      => $dists,
            packages           => $packages
        }
    );
}

sub _do_search {
    my $self    = shift;
    my $q       = shift;
    my $index   = $self->index;
    my @results = $index->search( $q );
    my $au_type = $self->author_type;
    my ( @authors, @distributions, @packages );

    if ( $q !~ /\w(?:::|-)\w/ ) {
        @authors = uniq grep { ref( $_ ) eq "Parse::CPAN::${au_type}::Author" } @results;
    }
    if ( $q !~ /\w::\w/ ) {
        @distributions = uniq grep { ref( $_ ) eq 'Parse::CPAN::Packages::Distribution' } @results;
    }
    if ( $q !~ /\w-\w/ ) {
        @packages = uniq grep { ref( $_ ) eq 'Parse::CPAN::Packages::Package' } @results;
    }

    @authors = sort { $a->name cmp $b->name } @authors;

    @distributions = sort {
        my @acount = $a->dist =~ /-/g;
        my @bcount = $b->dist =~ /-/g;
        scalar( @acount ) <=> scalar( @bcount )
          || $a->dist cmp $b->dist
    } @distributions;

    @packages = sort {
        my @acount = $a->package =~ /::/g;
        my @bcount = $b->package =~ /::/g;
        scalar( @acount ) <=> scalar( @bcount )
          || $a->package cmp $b->package
    } @packages;

    return ( \@authors, \@distributions, \@packages );

}

sub author_page {
    my $self    = shift;
    my $pauseid = $self->pauseid;

    my @distributions = sort { $a->distvname cmp $b->distvname }
      grep { $_->cpanid eq uc $pauseid } $self->parse_cpan_packages->distributions;
    my $author = $self->parse_cpan_authors->author( uc $pauseid );

    my $checksum = $self->checksum_data_for_author( uc $pauseid );
    my %dates;
    if ( not $@ and defined $checksum ) {
        foreach my $dist ( @distributions ) {
            $dates{ $dist->distvname } = $checksum->{ $dist->filename }->{mtime};
        }
    }

    $self->send_http_header( 200, -charset => 'utf-8' );
    return Template::Declare->show(
        'author',
        {
            author        => $author,
            pauseid       => $pauseid,
            distributions => \@distributions,
            dates         => \%dates,
        }
    );
}

sub distribution_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;

    # TODO: need to figure out how to handle dists missing here
    my ( $distribution ) = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname } $self->parse_cpan_packages->distributions;

    my $filename = $distribution->distvname . "/META.yml";
    my $metastr  = $self->get_file_from_tarball( $distribution, $filename );
    my $meta     = {};
    my @yaml     = eval { Parse::CPAN::Meta::Load( $metastr ); };
    $meta = $yaml[0] if !$@;

    my $checksum_data = $self->checksum_data_for_author( uc $pauseid );
    $meta->{'release date'} = $checksum_data->{ $distribution->filename }->{mtime};

    my @filenames = $self->list_files( $distribution );

    $self->send_http_header( 200, -charset => 'utf-8' );
    return Template::Declare->show(
        'distribution',
        {
            author       => $self->parse_cpan_authors->author( uc $pauseid ),
            distribution => $distribution,
            pauseid      => $pauseid,
            distvname    => $distvname,
            filenames    => \@filenames,
            meta         => $meta,
            pcp          => $self->parse_cpan_packages,
        }
    );
}

sub pod_page {
    my $self = shift;
    my ( $pkgname ) = $self->cgi->keywords;

    my $m = $self->parse_cpan_packages->package( $pkgname );
    my $d = $m->distribution;

    my ( $pauseid, $distvname ) = ( $d->cpanid, $d->distvname );
    my $url = "/package/$pauseid/$distvname/$pkgname/";

    $self->redirect( $url );
}

sub install_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;

    my ( $distribution ) = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname } $self->parse_cpan_packages->distributions;

    my $file = file( $self->directory, 'authors', 'id', $distribution->prefix );

    $self->send_http_header( 200 );
    printf '<html><body><h1>Installing %s</h1><pre>', $distribution->distvname;

    warn sprintf "Installing '%s'\n", $distribution->prefix;

    require CPAN;    # loads CPAN::Shell
    CPAN::Shell->install( $distribution->prefix );

    printf '</pre><a href="/~%s/%s">Go back</a></body></html>', $self->pauseid, $self->distvname;
}

sub file_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;
    my $filename  = $self->filename;

    my ( $distribution ) = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname } $self->parse_cpan_packages->distributions;

    my $contents = $self->get_file_from_tarball( $distribution, $filename );

    my $parser = Pod::Simple::HTML->new;
    $parser->perldoc_url_prefix( '/perldoc?' );
    $parser->index( 0 );
    $parser->no_whining( 1 );
    $parser->no_errata_section( 1 );
    $parser->output_string( \my $html );
    $parser->parse_string_document( $contents );
    $html =~ s/^.*<!-- start doc -->//s;
    $html =~ s/<!-- end doc -->.*$//s;

    $self->send_http_header( 200, -charset => 'utf-8' );
    return Template::Declare->show(
        'file',
        {
            author       => $self->parse_cpan_authors->author( uc $pauseid ),
            distribution => $distribution,
            pauseid      => $pauseid,
            distvname    => $distvname,
            filename     => $filename,
            contents     => $contents,
            html         => $html,
        }
    );
}

sub download_file {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;
    my $filename  = $self->filename;

    my ( $distribution ) = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname } $self->parse_cpan_packages->distributions;

    return $self->redirect( "/authors/id/" . $distribution->prefix ) if !$filename;

    my $contents = $self->get_file_from_tarball( $distribution, $filename );
    $self->send_http_header(
        200,
        -content_type   => 'text/plain',
        -content_length => length $contents,
    );

    return $contents;
}

sub raw_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;
    my $filename  = $self->filename;

    my ( $distribution ) = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname } $self->parse_cpan_packages->distributions;

    my $file = file( $self->directory, 'authors', 'id', $distribution->prefix );

    my $contents = $self->get_file_from_tarball( $distribution, $filename );

    my $html;

    if ( $filename =~ /\.(pm|pl|PL|t)$/ ) {
        my $document  = PPI::Document->new( \$contents );
        my $highlight = PPI::HTML->new( line_numbers => 0 );
        my $pretty    = $highlight->html( $document );

        my $split = '<span class="line_number">';

        # turn significant whitespace into &nbsp;
        my @lines = map {
            $_ =~ s{</span>( +)}{"</span>" . ("&nbsp;" x length($1))}e;
            "$split$_";
        } split /$split/, $pretty;

        # remove the extra line number tag
        @lines = map { s{<span class="line_number">}{}; $_ } @lines;

        # remove newlines
        $_ =~ s{<br>}{}g foreach @lines;

        # link module names to ourselves
        @lines = map {
            $_ =~ s{<span class="word">([^<]+?::[^<]+?)</span>}{<span class="word"><a href="/perldoc?$1">$1</a></span>}g;
            $_;
        } @lines;
        $html = join '', @lines;
    }

    $self->send_http_header( 200, -charset => 'utf-8' );
    return Template::Declare->show(
        'raw',
        {
            author       => $self->parse_cpan_authors->author( uc $pauseid ),
            distribution => $distribution,
            filename     => $filename,
            pauseid      => $pauseid,
            distvname    => $distvname,
            contents     => $contents,
            html         => $html,
        }
    );
}

sub dist_page {
    my $self = shift;
    my ( $dist ) = $self->cgi->path_info =~ m{^/dist/(.+?)$};
    my $latest = $self->parse_cpan_packages->latest_distribution( $dist );
    if ( $latest ) {
        $self->redirect( "/~" . $latest->cpanid . "/" . $latest->distvname );
    }
    else {
        $self->not_found_page( $dist );
    }
}

sub package_page {
    my $self = shift;
    my $path = $self->cgi->path_info;
    my ( $pauseid, $distvname, $package_name ) = $path =~ m{^/package/(.+?)/(.+?)/(.+?)/$};

    my ( $p ) = grep $self->is_package_for_package_page( $pauseid, $distvname, $package_name, $_ ), $self->parse_cpan_packages->packages;
    my $distribution = $p->distribution;
    my @filenames    = $self->list_files( $distribution );
    my $package_file = $package_name;
    $package_file =~ s{::}{/}g;
    $package_file .= '.pm';
    my ( $filename ) = grep { $_ =~ /$package_file/ } sort { length( $a ) <=> length( $b ) } @filenames;
    my $url = "/~$pauseid/$distvname/$filename";

    # TODO: duplicate results and no results here need to be handled (maybe search through contents of a dist in that case)

    $self->redirect( $url );
}

sub is_package_for_package_page {
    my ( $self, $pauseid, $distvname, $package_name, $package ) = @_;

    return 0 if $package->package                 ne $package_name;
    return 0 if $package->distribution->distvname ne $distvname;
    return 0 if $package->distribution->cpanid    ne uc $pauseid;

    return 1;
}

sub download_cpan {
    my ( $self, $prefix ) = @_;
    my $file_type = File::Type->new;
    my $file = file( $self->directory, canonpath( URI::Escape::uri_unescape( $prefix ) ) );

    open my $fh, $file or return $self->not_found_page( $prefix );

    my $content_type = $file_type->checktype_filename( $file );
    $content_type = 'text/plain' unless $file->basename =~ /\./;

    $self->send_http_header(
        200,
        -content_type        => $content_type,
        -content_disposition => "attachment; filename=" . $file->basename,
        -content_length      => -s $fh,
    );
    while ( <$fh> ) {
        print;
    }
    $fh->close;

}

sub list_files {
    my ( $self, $distribution ) = @_;
    my $file = file( $self->directory, 'authors', 'id', $distribution->prefix );
    my $peek = Archive::Peek->new( filename => $file );
    my @filenames = $peek->files;
    return @filenames;
}

sub direct_to_template {
    my $self     = shift;
    my $template = shift;
    my $mime     = shift;

    $self->send_http_header(
        200,
        -expires => '+1d',
        ( $mime ? ( -type => $mime ) : () ),
    );

    return Template::Declare->show( $template );
}

1;

__END__

=head1 NAME

CPAN::Mini::Webserver - Search and browse Mini CPAN

=head1 SYNOPSIS

  % minicpan_webserver

=head1 DESCRIPTION

This module is the driver that provides a web server that allows
you to search and browse Mini CPAN. First you must install
CPAN::Mini and create a local copy of CPAN using minicpan.
Then you may run minicpan_webserver and search and
browse Mini CPAN at http://localhost:2963/.

You may access the Git repository at:

  https://github.com/wchristian/cpan-mini-webserver

And may send support requests on RT.

=head1 CURRENT MAINTAINER

Christian Walde <walde.christian@googlemail.com>

=head1 AUTHOR

Leon Brocard <acme@astray.com>

=head1 COPYRIGHT

Copyright (C) 2008, Leon Brocard.

=head1 LICENSE

This module is free software; you can redistribute it or
modify it under the same terms as Perl itself.

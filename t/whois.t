#!perl
use strict;
use warnings;

use Test::InDistDir;
use lib 't';

use Test::More;
use WebserverTester qw( setup_test_minicpan html_page_ok );
use CPAN::Mini::Webserver;

plan tests => 2;

setup_test_minicpan( "t/mini_whois" );

my $html = html_page_ok( "~andk/" );
like( $html, qr/CPAN-Test-Dummy-Perl5-Build-1.03/, "mirror with 00whois.xml does not cause a crash" );

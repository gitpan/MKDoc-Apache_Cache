package MKDoc::Apache_Cache::Capture;
use base qw /Apache::RegistryNG Apache/;


sub new
{
    my ($class, $r) = @_;
    $r ||= Apache->request();
    
    tie *STDOUT, $class, $r;
    return tied *STDOUT;
}


sub print
{
    my $self = shift;
    $self->{_data} ||= '';
    $self->{_data} .= join ('', @_);
}


sub data
{
    my $self = shift;
    return $self->{_data}; 
}


sub TIEHANDLE
{
    my ($class, $r) = @_;
    return bless { r => $r, _r => $r, _data => undef }, $class;
}


sub PRINT
{
    shift->print (@_);
}


package MKDoc::Apache_Cache;
use base qw /Apache::RegistryNG/;
use strict;
use warnings;
use Apache;
use Apache::Constants;
use MKDoc::Control_List;
use Cache::FileCache;
use vars qw /$Request/;
use CGI;

our $VERSION = '0.1';


sub handler ($$)
{
    my ($class, $r) = (@_ >= 2) ? (shift, shift) : (__PACKAGE__, shift);
    
    # Makes $MKDoc::Apache_Cache::Request available
    local $Request = $r;
    
    my @args = $class->_control_list_process();
    my ($ret, $data) = $class->_do_cached (@args);
    $r->print ($data);
    
    return $ret;
}


sub _do_cached
{
    my $class      = shift;
    
    my $timeout    = shift || return $class->_do_request();
    my $identifier = shift || $class->_default_identifier();
    
    my $cache_obj  = $class->_cache_object();
    my $cached     = $cache_obj->get ($identifier) || do {
	my ($ret, $data) = $class->_do_request();
	my $tocache = $ret . "\n" . $data;
	$cache_obj->set ($identifier, $tocache, $timeout);
	return $tocache;
    };
    
    return split /\n/, $cached, 2;
}


sub _do_request
{
    my $class  = shift;
    my $fake_r = MKDoc::Apache_Cache::Capture->new ($Request);
    my $ret    = $class->SUPER::handler ($fake_r);
    return ($ret, $fake_r->data());
}


sub _default_identifier
{
    my $class = shift;
    return CGI->new()->self_url();
}


sub _control_list_process
{
    my $class = shift;
    my $key   = 'MKDoc_Apache_Cache_CONFIG';
    my $file  = Apache->request->dir_config ($key) || $ENV{$key} || '/etc/mkdoc-apache-cache.conf';
    -e $file && -f $file || do {
	warn "Cannot stat $file - skipping";
	return ();
    };
    
    my $ctrl  = new MKDoc::Control_List ( file => $file );
    return $ctrl->process();
}


sub _cache_object
{
    my $class = shift;
    my %args  = ();
    
    $class->_cache_object_option ('namespace', \%args);
    $class->_cache_object_option ('default_expires_in', \%args);
    $class->_cache_object_option ('auto_purge_interval', \%args);
    $class->_cache_object_option ('auto_purge_on_set', \%args);
    $class->_cache_object_option ('auto_purge_on_get', \%args);
    $class->_cache_object_option ('cache_root', \%args);
    $class->_cache_object_option ('cache_depth', \%args);
    $class->_cache_object_option ('directory_umask', \%args);
    
    return new Cache::FileCache ( \%args );
}


sub _cache_object_option
{
    my $self = shift;
    my $opt  = shift;
    my $args = shift;
    my $key  = 'MKDoc_Apache_Cache_' . uc ($opt);
    my $val  = Apache->request->dir_config ($key) || $ENV{$key};
    defined $val and do { $args->{$opt} = $val };
}


1;

__END__


=head1 NAME

MKDoc::Apache_Cache - Extra speed for Apache::Registry scripts


=head1 SYNOPSIS

In your httpd.conf file instead of having:

    PerlHandler Apache::Registry

You have something like:

    PerlSetEnv  MKDoc_Apache_Cache_CONFIG           /opt/groucho/cache_policy.txt
    PerlSetEnv  MKDoc_Apache_Cache_CACHE_ROOT       /opt/groucho/cache
    PerlSetEnv  MKDoc_Apache_Cache_NAMESPACE        apache_cache
    PerlHandler MKDoc::Apache_Cache

You also need to define your cache policies in the cache_policy.txt file,
otherwise it won't cache anything.


=head1 SUMMARY

L<MKDoc::Apache_Cache> is a drop-in replacement for Apache::Registry. It lets you very
fine caching policies using the L<MKDoc::Control_List> module and uses L<Cache::FileCache>
as its caching backend.


=head1 DEFINING CACHING POLICIES

The cache_policy.txt (or whatever you choose to call it) file is split into three
parts: conditions, return values, and the policies themselves.


=head2 Defining conditions

Conditions are the building blocks of your rules, they are either true or false.

You can define a condition as follows:

  CONDITION <condition_name> <perl_expression>

condition_name must be a simple string such_as_this_one.

perl_expression can be any Perl expression as long as it's on one line.

Example:

  CONDITION is_slash      $ENV{PATH_INFO} =~ /\/$/
  CONDITION is_sitemap    $ENV{PATH_INFO} =~ /\.sitemap.html$/
  CONDITION is_chris      $ENV{REMOTE_USER} eq 'chris'

In this case we've defined three conditions:

'is_slash' will be true when the request points to a URI which ends by a slash.

'is_sitemap' will be true when the requests points to a URI which -presumably-
will display a dynamically generated sitemap.

'is_chris' will be true when the authenticated user is chris.


=head2 Defining return values

Now we've got two conditions, we can define some cache times. The syntax is as follows:

  RET_VALUE <ret_value_name> <perl_expression>

The value returned by <perl_expression> must be something that L<Cache::Cache> can understand,
namely (from perldoc Cache::Cache):

The valid units are s, second, seconds, sec, m, minute, minutes, min, h, hour, hours, w, week,
weeks, M, month, months, y, year, and years.  Additionally, $EXPIRES_NOW can be represented as
"now" and $EXPIRES_NEVER can be represented as "never".

So for example:

  RET_VALUE 10_minutes "10 min"
  RET_VALUE one_day    "24 hours"
  RET_VALUE never      "never"


=head2 Defining cache policies

Let's say that in general, you want to cache URIs which end by a slash for 10 minutes.

URIs which point to sitemap need to be cached for a day since they are very CPU intensive.

But the user 'chris' needs to see the sitemap always up to date since he's working on the
site, so for chris the sitemap musn't be cached.

You would do it as follows:

  RULE never        WHEN is_sitemap is_chris
  RULE one_day      WHEN is_sitemap
  RULE ten_minutes  WHEN is_slash

This translates as:

IF is_sitemap AND is_chris are true, never cache

ELSE IF is_sitemap is true, cache for a day

ELSE IF is_slash is true, cache for ten minutes

ELSE don't cache.

See also L<MKDoc::Control_List> for more examples of crazy rules.


=head1 EXPORTS

None.


=head1 KNOWN BUGS

None, which probably means plenty of unknown bugs :)


=head1 ABOUT

MKDoc is a web content management system written in Perl which focuses on
standards compliance, accessiblity and usability issues, and multi-lingual
websites.

At MKDoc Ltd we have decided to gradually break up our existing commercial
software into a collection of completely independent, well-documented,
well-tested open-source CPAN modules.

Ultimately we want MKDoc code to be a coherent collection of module
distributions, yet each distribution should be usable and useful in itself.

L<MKDoc::Apache_Cache> is part of this effort.

You could help us and turn some of MKDoc's code into a CPAN module.
You can take a look at the existing code at http://download.mkdoc.org/.

If you are interested in some functionality which you would like to
see as a standalone CPAN module, send an email to <mkdoc-modules@lists.webarch.co.uk>.


=head1 AUTHOR

Copyright 2003 - MKDoc Holdings Ltd.

Author: Jean-Michel Hiver <jhiver@mkdoc.com>

This module is free software and is distributed under the same license as Perl
itself. Use it at your own risk.


=head1 SEE ALSO

Help us open-source MKDoc. Join the mkdoc-modules mailing list:

  mkdoc-modules@lists.webarch.co.uk

=cut

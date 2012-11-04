package GitStore;
BEGIN {
  $GitStore::AUTHORITY = 'cpan:YANICK';
}
{
  $GitStore::VERSION = '0.12';
}
#ABSTRACT: Git as versioned data store in Perl

use Moose;
use Moose::Util::TypeConstraints;
use Git::PurePerl;
use Carp;
use Storable qw(nfreeze thaw);

use Path::Class qw/ dir file /;

use List::Util qw/ first /;

no warnings qw/ uninitialized /;

subtype 'PurePerlActor' =>
    as 'Git::PurePerl::Actor';

coerce PurePerlActor 
    => from 'Str'
    => via { 
    s/<(.*?)>//;
    Git::PurePerl::Actor->new( name => $_, email => $1 );
};

has 'repo' => ( is => 'ro', isa => 'Str', required => 1 );
has 'branch' => ( is => 'rw', isa => 'Str', default => 'master' );
has author => ( 
    is => 'rw', 
    isa => 'PurePerlActor',  
    default => sub { 
        Git::PurePerl::Actor->new( 
            name  => 'anonymous', 
            email => 'anon@127.0.0.1' 
        );
} );

sub _clean_directories {
    my ( $self, $dir ) = @_;

    $dir ||= $self->root;

    my $nbr_files = keys %{ $dir->{FILES} };

    for my $d ( keys %{ $dir->{DIRS} } ) {
        if( my $f = $self->_clean_directories( $dir->{DIRS}{$d} ) ) {
            $nbr_files += $f;
        }
        else {
            delete $dir->{DIRS}{$d};
        }
    }

    return $nbr_files;
}

sub _expand_directories {
    my( $self, $object ) = @_;

    my %dir = ( DIRS => {}, FILES => {} );

    for my $entry ( map { $_->directory_entries } $object ) {
        if ( $entry->object->isa( 'Git::PurePerl::Object::Tree' ) ) {
            $dir{DIRS}{$entry->filename} 
                = $self->_expand_directories( $entry->object );
        }
        else {
            $dir{FILES}{$entry->filename} = $entry->sha1;
        }
    }

    return \%dir;
}

has 'root' => ( is => 'rw', isa => 'HashRef', default => sub { {} } );

has 'git' => (
    is => 'ro',
    isa => 'Git::PurePerl',
    lazy => 1,
    default => sub {
        my $repo = $_[0]->repo;
        return Git::PurePerl->new( 
            ( $repo =~ m/\.git$/ ? 'gitdir' : 'directory') => $repo 
        );
    }
);

sub BUILD {
    my $self = shift;
    
    $self->load();
    
}

sub BUILDARGS {
    my $class = shift;

    if ( @_ == 1 && ! ref $_[0] ) {
        return { repo => $_[0] };
    } else {
        return $class->SUPER::BUILDARGS(@_);
    }
}

sub branch_head {
    my ( $self, $branch ) = @_;
    $branch ||= $self->branch;

    return $self->git->ref_sha1('refs/heads/' . $branch);
}

# Load the current head version from repository. 
sub load {
    my $self = shift;
    
    my $head = $self->branch_head or do {
        $self->root({ DIRS => {}, FILES => {} });
        return;
    };

    my $commit = $self->git->get_object($head);
    my $tree = $commit->tree;

    my $root = $self->_expand_directories( $tree );
    $self->root($root);

}

sub _normalize_path {
    my ( $self, $path ) = @_;

    $path = join '/', @$path if ref $path eq 'ARRAY';

    # Git doesn't like paths prefixed with a '/'
    $path =~ s#^/+##;

    return $path;
}

sub get {
    my ( $self, $path ) = @_;
    
    $path = file( $self->_normalize_path($path) );

    my $dir = $self->_cd_dir($path) or return;

    my $sha1 = $dir->{FILES}{$path->basename} or return;

    my $object = $self->git->get_object($sha1) or return;

    return _cond_thaw($object->content);
}

sub set {
    my ( $self, $path, $content ) = @_;
    
    $path = file( $self->_normalize_path($path) );

    my $dir = $self->_cd_dir($path,1) or return;

    $content = nfreeze( $content ) if ( ref $content );

    my $blob = Git::PurePerl::NewObject::Blob->new( content => $content );
    $self->git->put_object($blob);

    $dir->{FILES}{$path->basename} = $blob->sha1;
}

*remove = \&delete;
sub delete {
    my ( $self, $path ) = @_;
    
    $path = file( $self->_normalize_path($path) );

    my $dir = $self->_cd_dir($path) or return;

    return delete $dir->{FILES}{$path->basename};
}

sub _cd_dir {
    my( $self, $path, $create ) = @_;

    my $dir = $self->root;

    for ( grep { !/^\.$/ } $path->dir->dir_list ) {
        if ( $dir->{DIRS}{$_} ) {
            $dir = $dir->{DIRS}{$_};
        }
        else {
            return unless $create;
            $dir = $dir->{DIRS}{$_} = { DIRS => {}, FILES => {} };
        }
    }

    return $dir;
}

sub _build_new_directory_entry {
    my( $self, $dir ) = @_;

    my @children;
    
    while ( my( $filename, $sha1 ) = each %{ $dir->{FILES} } ) {
        push @children,
            Git::PurePerl::NewDirectoryEntry->new(
                mode     => '100644',
                filename => $filename,
                sha1     => $sha1,
            );
    }

    while ( my( $dirname, $dir ) = each %{ $dir->{DIRS} } ) {
        my $tree = $self->_build_new_directory_entry($dir);
        push @children, Git::PurePerl::NewDirectoryEntry->new(
            mode     => '040000',
            filename => $dirname,
            sha1     => $tree->sha1,
        );
    }

    my $tree = Git::PurePerl::NewObject::Tree->new(
        directory_entries => \@children,
    );
    $self->git->put_object($tree);

    return $tree;
}

sub commit {
    my ( $self, $message ) = @_;

    unless ( $self->_clean_directories ) {
        # TODO surely there's a better way?
        $self->set( '.gitignore/dummy', 'dummy file to keep git happy' );
    }
    
    # TODO only commit if there were changes
    
    my $tree = $self->_build_new_directory_entry( $self->root );

    # there might not be a parent, if it's a new branch
    my $parent = eval { $self->git->ref( 'refs/heads/'.$self->branch )->sha1 };

    my $timestamp = DateTime->now;
    my $commit = Git::PurePerl::NewObject::Commit->new(
        ( parent => $parent ) x !!$parent,
        tree => $tree->sha1,
        author => $self->author,
        committer => $self->author,
        comment => $message||'',
        authored_time  => $timestamp,
        committed_time => $timestamp,
    );
    $self->git->put_object($commit);

    # reload
    $self->load;
}

sub discard {
    my $self = shift;

    $self->load;
}

sub _cond_thaw {
    my $data = shift;

    my $magic = eval { Storable::read_magic($data); };
    if ($magic && $magic->{major} && $magic->{major} >= 2 && $magic->{major} <= 5) {
        my $thawed = eval { Storable::thaw($data) };
        if ($@) {
            # false alarm... looked like a Storable, but wasn't.
            return $data;
        }
        return $thawed;
    } else {
        return $data;
    }
}

sub _find_file {
    my( $self, $tree, $path ) = @_;

    my @path = grep { !/^\.$/ } $path->dir->dir_list;

    if ( my $part = shift @path ) {
        my $entry = first { $_->filename eq $part } $tree->directory_entries 
            or return;

        my $object = $self->git->get_object( $entry->sha1 );

        return unless ref $object eq 'Git::PurePerl::Object::Tree';

        return $self->_find_file( $object, file(@path,$path->basename) );
    }

    return first { $_->filename eq $path->basename } $tree->directory_entries;
}

sub history {
    my ( $self, $path ) = @_;

    require GitStore::Revision;

    my $head = $self->git->ref_sha1('refs/heads/' . $self->branch)
        or return;

    my @q = ( $self->git->get_object($head) );

    my @commits;
    while ( @q ) {
        push @q, $q[0]->parents;
        unshift @commits, shift @q;
    }

    my @history_commits;
    my %sha1_seen;

    for my $c ( @commits ) {
        my $file = $self->_find_file( $c->tree, file($path) ) or next;
        push @history_commits, $c unless $sha1_seen{ $file->object->sha1 }++;        
    }

    return map {
        GitStore::Revision->new( 
            path => $path, 
            gitstore => $self,
            sha1 => $_->sha1,
        )
    } @history_commits;

}

sub list {
    my( $self, $regex ) = @_;

    croak "'$regex' is not a a regex"
        if $regex and ref $regex ne 'Regexp';

    my $head = $self->branch_head or return;

    my $commit = $self->git->get_object($head);
    my $tree = $commit->tree;

    my $root = $self->_expand_directories( $tree );

    my @dirs = ( [ '', $root ] );
    my @entries;

    while( my $dir = shift @dirs ) {
        my $path = $dir->[0];
        $dir = $dir->[1];
        unshift @dirs, [ "$path/$_" => $dir->{DIRS}{$_} ]
            for sort keys  %{$dir->{DIRS}}; 

        for ( sort keys %{$dir->{FILES}} ) {
            my $f = "$path/$_";
            $f =~ s#^/##;  # TODO improve this
            next if $regex and $f !~ $regex;
            push @entries, $f;
        }
    }

    return @entries;
}


no Moose;
__PACKAGE__->meta->make_immutable;

1;

__END__

=pod

=head1 NAME

GitStore - Git as versioned data store in Perl

=head1 VERSION

version 0.12

=head1 SYNOPSIS

    use GitStore;

    my $gs = GitStore->new('/path/to/repo');
    $gs->set( 'users/obj.txt', $obj );
    $gs->set( ['config', 'wiki.txt'], { hash_ref => 1 } );
    $gs->commit();
    $gs->set( 'yyy/xxx.log', 'Log me' );
    $gs->discard();
    
    # later or in another pl
    my $val = $gs->get( 'user/obj.txt' ); # $val is the same as $obj
    my $val = $gs->get( 'config/wiki.txt' ); # $val is { hashref => 1 } );
    my $val = $gs->get( ['yyy', 'xxx.log' ] ); # $val is undef since discard

=head1 DESCRIPTION

It is inspired by the Python and Ruby binding. check SEE ALSO

=head1 METHODS

=head2 new

    GitStore->new('/path/to/repo');
    GitStore->new( repo => '/path/to/repo', branch => 'mybranch' );
    GitStore->new( repo => '/path/to/repo', author => 'Someone Unknown <unknown\@what.com>' );

=over 4

=item repo

your git directory or work directory (I<GitStore> will assume it's a work
directory if it doesn't end with C<.git>).

=item branch

your branch name, default is 'master'

=item author

It is used in the commit info

=back

=head2 set($path, $val)

    $gs->set( 'yyy/xxx.log', 'Log me' );
    $gs->set( ['config', 'wiki.txt'], { hash_ref => 1 } );
    $gs->set( 'users/obj.txt', $obj );

Store $val as a $path file in Git

$path can be String or ArrayRef. Any leading slashes ('/') in the path
will be stripped, as to make it a valid Git path.  The same 
grooming is done for the C<get()> and C<delete()> methods.

$val can be String or Ref[HashRef|ArrayRef|Ref[Ref]] or blessed Object

=head2 get($path)

    $gs->get( 'user/obj.txt' );
    $gs->get( ['yyy', 'xxx.log' ] );

Get $val from the $path file

$path can be String or ArrayRef

=head2 delete($path)

=head2 remove($path)

remove $path from Git store

=head2 commit

    $gs->commit();
    $gs->commit('Your Comments Here');

commit the B<set> changes into Git

=head2 discard

    $gs->discard();

discard the B<set> changes

=head2 history($path)

Returns a list of L<GitStore::Revision> objects representing the changes
brought to the I<$path>. The changes are returned in ascending commit order.

=head2 list($regex)

    @entries = $gs->list( qr/\.txt$/ );

Returns a list of all entries in the repository, possibly filtered by the 
optional I<$regex>.

=head1 FAQ

=head2 why the files are B<not> there?

run

    git checkout

=head2 any example?

    # if you just need a local repo, that's all you need.
    mkdir sandbox
    cd sandbox
    git init
    # use GitStore->new('/path/to/this/sandbox')
    # set something
    git checkout
    
    # follows are for remote git url
    git remote add origin git@github.com:fayland/sandbox2.git
    git push origin master
    # do more GitStore->new('/path/to/this/sandbox') later
    git checkout
    git pull origin master
    git push

=head1 KNOWN BUGS

If all files are deleted from the repository, a 'dummy' file
will be created to keep Git happy.

=head1 SEE ALSO

=over 4

=item Article

L<http://www.newartisans.com/2008/05/using-git-as-a-versioned-data-store-in-python.html>

=item Python binding

L<http://github.com/jwiegley/git-issues/tree/master>

=item Ruby binding

L<http://github.com/georgi/git_store/tree/master>

=back

=head1 Git URL

L<http://github.com/fayland/perl-git-store/tree/master>

=head1 AUTHORS

=over 4

=item *

Fayland Lam <fayland@gmail.com>

=item *

Yanick Champoux <yanick@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by Fayland Lam <fayland@gmail.com>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

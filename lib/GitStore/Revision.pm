package GitStore::Revision;
#ABSTRACT: the state of a given path for a specific commit

=head1 SYNOPSIS

   use GitStore;

   my $gs = GitStore->new('/path/to/repo');

   my @history = $gs->history( 'path/to/object' );

   for my $rev ( @history ) {
        say "modified at: ", $rev->timestamp;
        say "commit message was: ", $rev->message;
        say "===\n", $rev->content;
   }

=head1 DESCRIPTION

Represents an object in a  L<GitStore> at a specific commit.

=cut

use strict;
use warnings;

use Moose;

use GitStore;
use DateTime;
use List::Util qw/ first /;
use Path::Class;

=head1 METHODS

=head2 sha1

Returns the SHA-1 of the commit.

=cut

has sha1 => (
    is => 'ro',
    required => 1,
);

=head2 commit_object

Returns the L<Git::PurePerl::Object::Commit> object containing the file revision.

=cut

=head2 timestamp

Returns the commit time of the revision as a L<DateTime> object.

=cut

=head2 message

Returns the commit message of the revision.  Note that the message might have
additional trailing carriage returns.

=cut

has commit_object => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;

        return $self->git->get_object($self->sha1);
    },
    handles => {
        timestamp => 'authored_time',
        message   => 'comment',
    },
);

=head2 path

Returns the path of the L<GitStore> object.

=cut

has path => (
    is => 'ro',
    required => 1,
);

has gitstore => (
    is => 'ro',
    isa => 'GitStore',
    required => 1,
    handles => {
        git_repo => 'git_repo',
        git => 'git',
    },
);

has file_object => ( 
    is => 'ro',
    lazy => 1,
    default => sub { 
        my $self = shift;

        $self->gitstore->_find_file( 
            $self->commit_object->tree, file($self->path) 
        );
    },
);


=head2 content

Returns the content of the object.  If the object is a frozen ref, the
structure will be returned, like for `GitStore`'s `get()`.

=cut

sub content {
    my $self = shift;

    $self->gitstore->deserializer->($self->gitstore,$self->path,$self->file_object->object->content);
}


__PACKAGE__->meta->make_immutable;
1;

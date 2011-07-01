package Dancer::Plugin::Database::Handle;

use strict;
use Carp;
use DBI;
use base qw(DBI::db);

our $VERSION = '0.06';

=head1 NAME

Dancer::Plugin::Database::Handle - subclassed DBI connection handle

=head1 DESCRIPTION

Subclassed DBI connection handle with added convenience features


=head1 SYNOPSIS

  # in your Dancer app:
  database->quick_insert($tablename, \%data);

  # Updating a record where id = 42:
  database->quick_update($tablename, { id => 42 }, { foo => 'New value' });

  # Fetching a single row quickly in scalar context
  my $employee = database->quick_select('employees', { id => $emp_id });

  # Fetching multiple rows in list context - passing an empty hashref to signify
  # no where clause (i.e. return all rows -  so "select * from $table_name"):
  my @all_employees = database->quick_select('employees', {});


=head1 Added features

A C<Dancer::Plugin::Database::Handle> object is a subclassed L<DBI::db> L<DBI>
database handle, with the following added convenience methods:

=over 4

=item quick_insert

  database->quick_insert('mytable', { foo => 'Bar', baz => 5 });

Given a table name and a hashref of data (where keys are column names, and the
values are, well, the values), insert a row in the table.

=cut

sub quick_insert {
    my ($self, $table_name, $data) = @_;
    return $self->_quick_query('INSERT', $table_name, $data);
}

=item quick_update

  database->quick_update('mytable', { id => 42 }, { foo => 'Baz' });

Given a table name, a hashref describing a where clause and a hashref of
changes, update a row.

=cut

sub quick_update {
    my ($self, $table_name, $where, $data) = @_;
    return $self->_quick_query('UPDATE', $table_name, $data, $where);
}


=item quick_delete

  database->quick_delete($table, {  id => 42 });

Given a table name and a hashref to describe the rows which should be deleted
(the where clause - see below for further details), delete them.

=cut

sub quick_delete {
    my ($self, $table_name, $where) = @_;
    return $self->_quick_query('DELETE', $table_name, undef, $where);
}


=item quick_select

  my $row  = database->quick_select($table, { id => 42 });
  my @rows = database->quick_select($table, { id => 42 });

Given a table name and a hashref of where clauses (see below for explanation),
returns either the first matching row as a hashref, if called in scalar context,
or a list of matching rows as hashrefs, if called in list context.

=cut

sub quick_select {
    my ($self, $table_name, $where) = @_;
    # Make sure to call _quick_query in the same context we were called.
    # This is a little ugly, rewrite this perhaps.
    if (wantarray) {
        return ($self->_quick_query('SELECT', $table_name, undef, $where));
    } else {
        return $self->_quick_query('SELECT', $table_name, undef, $where);
    }
}

sub _quick_query {
    my ($self, $type, $table_name, $data, $where) = @_;
    
    if ($type !~ m{^ (SELECT|INSERT|UPDATE|DELETE) $}x) {
        carp "Unrecognised query type $type!";
        return;
    }
    if (!$table_name || ref $table_name) {
        carp "Expected table name as a straight scalar";
        return;
    }
    if (($type eq 'INSERT' || $type eq 'UPDATE')
        && (!$data || ref $data ne 'HASH')) 
    {
        carp "Expected a hashref of changes";
        return;
    }
    if (($type =~ m{^ (SELECT|UPDATE|DELETE) $}x)
        && (!$where || ref $where ne 'HASH')) {
        carp "Expected a hashref of where conditions";
        return;
    }

    $table_name = $self->quote_identifier($table_name);
    my @bind_params;
    my $sql = {
        SELECT => "SELECT * FROM $table_name ",
        INSERT => "INSERT INTO $table_name ",
        UPDATE => "UPDATE $table_name SET ",
        DELETE => "DELETE FROM $table_name ",
    }->{$type};
    if ($type eq 'INSERT') {
        $sql .= "("
            . join(',', map { $self->quote_identifier($_) } keys %$data)
            . ") VALUES ("
            . join(',', map { "?" } values %$data)
            . ")";
        push @bind_params, values %$data;
    }
    if ($type eq 'UPDATE') {
        $sql .= join ',', map { $self->quote_identifier($_) .'=?' } keys %$data;
        push @bind_params, values %$data;
    }
    
    if (($type eq 'UPDATE' || $type eq 'DELETE' || $type eq 'SELECT') 
        && keys %$where)
    {
        my @conditions;

        # Operators we'll accept - we need to prevent SQL injection, but we
        # can't quote them, so whitelist what's OK:
        my %known_operator = map { $_ => 1 }
            qw( = != < > <= >= LIKE like );
        
        for my $field (keys %$where) {
            my $value = $where->{$field};
            my $quoted_field = $self->quote_identifier($field);
            if (!ref $value) {
                if (!defined $value) {
                    push @conditions, "$quoted_field IS NULL";
                } else {
                    push @conditions, "$quoted_field = ?";
                    push @bind_params, $value;
                }
            } elsif (ref $value  eq 'ARRAY') {
                push @conditions, "$quoted_field IN ("
                    . join(',', map { "?" } @$value) . ")";
                push @bind_params, @$value;
            } elsif (ref $value eq 'HASH') {
                for my $operator (keys %$value) {
                    if (!$known_operator{uc $operator}) {
                        Dancer::Logger::error(
                            "Unrecognised operator '$operator'!"
                        );
                        return;
                    }
                    my $operand = $value->{$operator};
                    push @conditions, "$quoted_field $operator ?";
                    push @bind_params, $operand;
                }
            }
        }
        # OK, assemble that all:
        $sql .= "WHERE " . join " AND ", @conditions;
    }
    
    # If it's a select query and we're called in scalar context, we'll only
    # return one row, so add a LIMIT 1
    if ($type eq 'SELECT' && !wantarray) {
        $sql .= ' LIMIT 1';
    }

    # Dancer::Plugin::Database will have looked at the log_queries setting and
    # stashed it away for us to see:
    if ($self->{private_dancer_plugin_database}{log_queries}) {
        Dancer::Logger::debug(
            "Executing $type query $sql with params " . join ',', 
            map {
                defined $_ ? 
                $_ =~ /^[[:ascii:]]+$/ ? 
                    length $_ > 50 ? substr($_, 0, 47) . '...' : $_
                : "[non-ASCII data not logged]" : 'undef'
            } @bind_params
        );
    }

    # Select queries, in scalar context, return the first matching row; in list
    # context, they return a list of matching rows.
    if ($type eq 'SELECT') {
        if (wantarray) {
            return @{ 
                $self->selectall_arrayref(
                    $sql, { Slice => {} }, @bind_params
                )
            };
        } else {
            return $self->selectrow_hashref($sql, undef, @bind_params);
        }

    } else {
        # INSERT/UPDATE/DELETE queries just return the result of DBI's do()
        return $self->do($sql, undef, @bind_params);
    }
}


=back

All of the convenience methods provided take care to quote table and column
names using DBI's C<quote_identifier>, and use parameterised queries to avoid
SQL injection attacks.  See L<http://www.bobby-tables.com/> for why this is
important, if you're not familiar with it.


=head1 WHERE clauses as hashrefs

C<quick_update>, C<quick_delete> and C<quick_select> take a hashref of WHERE
clauses.  This is a hashref of field => 'value', each of which will be
included in the WHERE clause used, for instance:

  { id => 42 }

Will result in an SQL query which would include:

  WHERE id = 42

When more than one field => value pair is given, they will be ANDed together:

  { foo => 'Bar', bar => 'Baz' }

Will result in:

  WHERE foo = 'Bar' AND bar = 'Baz'

(Actually, parameterised queries will be used, with placeholders, so SQL
injection attacks will not work, but it's easier to illustrate as though the
values were interpolated directly.  Don't worry, they're not.))

You can also provide an arrayref if you want a set of acceptable values, for
instance:

  { author => [ qw(Bob Billy Mary) ] }

... will result in e.g.:

  WHERE author IN ('Bob', 'Billy', 'Mary')

(Except done with placeholders, as mentioned above)


You can pass an empty hashref if you  want all rows, e.g.:

  database->quick_select('mytable', {});

... is the same as C<"SELECT * FROM 'mytable'">

=head2 Match/comparison logic

The default for a straight scalar value as described above is a straightforward
match with C<=>, or an C<IN> clause if given an arrayref.

If you need to control the operator used for comparison, you can do so by
passing a hashref of C<operator => value>, for example:

  { price => { '>' => 15 } }

  { name => { 'LIKE' => 'Bob %' } }

An C<undef> value will result in an "IS NULL" in the SQL, for instance:

  { completed_date => undef }

... would result in:

  ... WHERE completed date IS NULL



=head1 AUTHOR

David Precious C< <<davidp@preshweb.co.uk >> >


=head1 SEE ALSO

L<Dancer::Plugin::Database>

L<Dancer>

L<DBI>

=cut

1;
__END__

use Mojolicious::Lite;
use Mojo::ByteStream;
use Mojo::JSON;
my $json = Mojo::JSON->new();

use DBM::Deep;
my $db = DBM::Deep->new( 'myapp.db' );

use lib 'lib';
use MojoCMS::DB::Schema;
my $schema = MojoCMS::DB::Schema->connect('dbi:SQLite:dbname=mysqlite.db');

#### some initial data ####
$db->{pages} ||= {
  home => { 
    name => 'home',
    title => 'Welcome',
    html => '<p>Welcome to the site!</p>',
    md   => 'Welcome to the site!',
  },
  me => { 
    name => 'me',
    title => 'About Me',
    html => '<p>Some really cool stuff about me</p>',
    md   => 'Some really cool stuff about me',
  },
};

$db->{main_menu} ||= {
  order => [ qw/ me / ],
  html  => '<li><a href="/pages/about">About Me</a></li>',
};
###########################

get '/' => sub {
  my $self = shift;
  $self->redirect_to('/pages/home');
};

get '/pages/:name' => sub {
  my $self = shift;
  my $name = $self->param('name');
  my $page = $schema->resultset('Page')->find({ name => $name });
  if ($page) {
    my $title = $page->title;
    $self->title( $title );
    $self->content_for( banner => $title );
    $self->render( pages => page_contents => $page->html );
  } else {
    if ($self->session->{username}) {
      $self->redirect_to("/edit/$name");
    } else {
      $self->render_not_found;
    }
  }
};

helper user_menu => sub {
  my $self = shift;
  my $user = $self->session->{username};
  my $html;
  if ($user) {
    my $url = $self->tx->req->url;
    my $edit_this_page = 
      $url =~ s{/pages/}{/edit/} 
      ? qq{<li><a href="$url">Edit This Page</a></li>} 
      : '';
    $html = <<USER;
<div class="well" style="padding: 8px 0;">
  <ul class="nav nav-list">
    <li class="nav-header">Hello $user</li>
    $edit_this_page
    <li><a href="/admin/menu">Setup Nav Menu</a></li>
    <li><a href="/logout">Log Out</a></li>
  </ul>
</div>
USER
  } else {
    $html = <<'ANON';
<form class="well" method="post" action="/login">
  <input type="text" class="input-small" placeholder="Username" name="username">
  <input type="password" class="input-small" placeholder="Password" name="password">
  <input type="submit" class="btn" value="Sign In">
</form>
ANON
  }
  return Mojo::ByteStream->new( $html );
};

helper 'set_menu' => sub {
  my ($self, $list) = @_;
  
  my @pages = 
    map { my $page = $_; $page =~ s/^pages-//; $page}
    grep { ! /^header-/ }
    @$list;
  $db->{main_menu}{order} = \@pages;
  
  $db->{main_menu}{html} = join "\n",
    map { sprintf '<li><a href="/pages/%s">%s</a></li>', $_, $db->{pages}{$_}{title} }
    @pages;

};

helper 'get_menu' => sub {
  my $self = shift;
  return $db->{main_menu}{html};
};

post '/login' => sub {
  my $self = shift;
  my $name = $self->param('username');
  my $pass = $self->param('password');

  my $user = $schema->resultset('User')->find({name => $name});
  if ($user and $user->pass eq $pass) {
    #TODO make this log the id for performance reasons
    $self->session->{username} = $name;
  }
  $self->redirect_to('/');
};

any '/logout' => sub {
  my $self = shift;
  $self->session( expires => 1 );
  $self->redirect_to('/');
};

under sub {
  my $self = shift;
  my $fail = sub {
    $self->redirect_to('/');
    return 0;
  };

  return $fail->() unless my $name = $self->session->{username};

  my $user = $schema->resultset('User')->find({name => $name});
  return $fail->() unless $user and $user->is_author;

  return 1;
};

get '/admin/menu' => sub {
  my $self = shift;
  my @active = @{ $db->{main_menu}{order} };
  my @inactive = do {
    my %active = map { $_ => 1 } @active;
    sort grep { length and not exists $active{$_} and not $_ eq 'home' } keys %{ $db->{pages} };
  };
  
  @active   = map { 
    sprintf '<li id="pages-%s">%s</li>', $_, $db->{pages}{$_}{title} 
  } @active;
  @inactive = map { 
    sprintf '<li id="pages-%s">%s</li>', $_, $db->{pages}{$_}{title} 
  } @inactive;
  
  my $active   = join( "\n", @active   ) . "\n";
  my $inactive = join( "\n", @inactive ) . "\n";

  $self->title( 'Setup Main Navigation Menu' );
  $self->content_for( banner => 'Setup Main Navigation Menu' );
  $self->render( menu => 
    active   => Mojo::ByteStream->new( $active   ), 
    inactive => Mojo::ByteStream->new( $inactive ),
  );
};

get '/edit/:name' => sub {
  my $self = shift;
  my $name = $self->param('name');
  $self->title( "Editing Page: $name" );
  $self->content_for( banner => "Editing Page: $name" );

  my $page = $schema->resultset('Page')->find({name => $name});
  if ($page) {
    my $title = $page->title;
    $self->stash( title_value => $title );
    $self->stash( input => $page->md );
  } else {
    $self->stash( title_value => '' );
    $self->stash( input => "Hello World" );
  }

  $self->render( 'edit' );
};

websocket '/store' => sub {
  my $self = shift;
  Mojo::IOLoop->stream($self->tx->connection)->timeout(300);
  $self->on(message => sub {
    my ($self, $message) = @_;
    my $data = $json->decode($message);
    my $store = delete $data->{store};

    if ($store eq 'pages') {
      unless($data->{title}) {
        $self->send('Not saved! A title is required!');
        return;
      }
      my $page = $schema->resultset('Page')->update_or_create(
        $data, {key => 'page_name'},
      );
      $self->set_menu($db->{main_menu}{order});
    } elsif ($store eq 'main_menu') {
       $self->set_menu($data->{list});
    }
    $self->send('Changes saved');
  });
};

get '/admin/dump' => sub {
  my $self = shift;
  require Data::Dumper;
  print Data::Dumper::Dumper($db);
  $self->redirect_to('/');
};

app->secret( 'MySecret' );
app->start;

__DATA__

@@ menu.html.ep
% layout 'standard';
% content_for header => begin
%= javascript '/assets/jquery-ui-1.8.21.custom.min.js'
% end

%= javascript begin
ws = new WebSocket("<%= url_for('store')->to_abs %>");
ws.onmessage = function (evt) {
  var message = evt.data;
  console.log( message );
  humane.log( message );
};
function saveButton() {
  var data = {
    store : "main_menu",
    list : $("#list-active-pages").sortable('toArray')
  };
  var serialized = JSON.stringify(data);
  console.log( "Sending ==> " + serialized );
  ws.send( serialized );
}

	$(function() {
		$( "#list-active-pages, #list-inactive-pages" ).sortable({
			connectWith: ".connectedSortable",
      items: "li:not(.nav-header)"
		}).disableSelection();
	});
%= end

<div class="row">
  <div class="span5">
    <ul id="list-active-pages" class="nav nav-list connectedSortable well">
      <li id="header-active" class="nav-header">Active Pages</li>
      <%= $active %>
    </ul>
  </div>
  <div class="span5">
    <ul id="list-inactive-pages" class="nav nav-list connectedSortable well">
      <li id="header-inactive" class="nav-header">Inactive Pages</li>
      <%= $inactive %>
    </ul>
  </div>
</div>
<button class="btn" id="save-list" onclick="saveButton()">
  Save
</button>

@@ edit.html.ep
% layout 'standard';
% content_for header => begin
%= stylesheet '/assets/pagedown/demo.css'
%= javascript '/assets/pagedown/Markdown.Converter.js'
%= javascript '/assets/pagedown/Markdown.Sanitizer.js'
%= javascript '/assets/pagedown/Markdown.Editor.js'
% end

%= javascript begin
data = {
  store : "pages",
  name  : "<%= $name  %>",
  md    : "",
  html  : "",
  title : ""
};

ws = new WebSocket("<%= url_for('store')->to_abs %>");
ws.onmessage = function (evt) {
  var message = evt.data;
  console.log( message );
  humane.log( message );
};

function saveButton() {
  data.title = $("#page-title").val();
  var serialized = JSON.stringify(data);
  console.log( "Sending ==> " + serialized );
  ws.send( serialized );
}

%= end

<div class="wmd-panel">
  <div class="well form-inline">
    <input 
      type="text" 
      id="page-title" 
      placeholder="Page Title" 
      value="<%= $title_value %>"
    >
    <button class="btn" id="save-md" onclick="saveButton()">
      Save Page
    </button>
  </div>
  <div id="wmd-button-bar"></div>
  <textarea class="wmd-input" id="wmd-input"><%= $input %></textarea>
  <div id="wmd-preview" class="wmd-preview well"></div>
  <div id="alert-area"></div>
</div>

%= javascript begin
(function () {
  var converter = Markdown.getSanitizingConverter();
  var editor = new Markdown.Editor(converter);
  converter.hooks.chain("preConversion", function (text) {
    data.md = text;
    return text; 
  });
  converter.hooks.chain("postConversion", function (text) {
    data.html = text;
    return text; 
  });
  editor.run();
})();
%= end

@@ pages.html.ep
% layout 'standard';
%== $page_contents

@@ layouts/standard.html.ep
<!DOCTYPE html>
<html>
<head>
  %= include 'header_common'
  <%= content_for 'header' %>
</head>
<body>
<div class="container">
  <div class="page-header">
    <h1><%= content_for 'banner' %></h1>
  </div>
  <div class="row">
    <div class="span2">
      <div class="well" style="padding: 8px 0;">
        <ul class="nav nav-list">
          <li class="nav-header">Navigation</li>
          <li><a href="/">Home</a></li>
          <%== get_menu %>
        </ul>
      </div>
      <%= user_menu %>
    </div>
    <div class="span10">
      <%= content %>
    </div>
  </div>
</div>
</body>
</html>

@@ header_common.html.ep
<title><%= title %></title>
%= javascript '/assets/jquery-1.7.2.min.js'
%= javascript '/assets/bootstrap/js/bootstrap.js'
%= stylesheet '/assets/bootstrap/css/bootstrap.css'
%= javascript '/assets/humane/humane.min.js'
%= stylesheet '/assets/humane/libnotify.css'
%= javascript begin
  humane.baseCls = 'humane-libnotify'
%= end


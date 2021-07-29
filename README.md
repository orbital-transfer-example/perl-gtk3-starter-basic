# perl-gtk3-starter

A repository for starting Perl Gtk3 projects.

# Resources

- Talk: [Cross-platform native GUIs: {trade,pay}offs, {integra,distribu}tion](https://github.com/zmughal-biblio/talk-tprc2021cic-cross-platform-native-guis-20210610)

# Development

## Localization

You can test localization by running:

```
    $ make -C po install; ( export LANG="fr_FR.UTF-8"; perl ./bin/app.pl ); make -C po clean
```

This will install the locale files into the project's share directory, run the
application using a French locale, and clean up afterwards.

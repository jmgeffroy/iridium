// Copyright (c) 2021 Mantano. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:dfunc/dfunc.dart';
import 'package:r2_commons_dart/utils/try.dart';
import 'package:r2_shared_dart/archive.dart';
import 'package:r2_shared_dart/fetcher.dart';
import 'package:r2_shared_dart/mediatype.dart';
import 'package:r2_shared_dart/publication.dart';
import 'package:r2_streamer_dart/parser.dart';
import 'package:r2_streamer_dart/pdf.dart';

class PublicationTry<SuccessT> extends Try<SuccessT, OpeningException> {
  PublicationTry.success(SuccessT success) : super.success(success);

  PublicationTry.failure(OpeningException failure) : super.failure(failure);
}

typedef OnCreatePublication = void Function(PublicationBuilder);

OnCreatePublication get _emptyOnCreatePublication => (pb) {};

/// Opens a Publication using a list of parsers.
///
/// The [Streamer] is configured to use Readium's default parsers, which you can bypass using
/// [ignoreDefaultParsers]. However, you can provide additional [parsers] which will take precedence
/// over the default ones. This can also be used to provide an alternative configuration of a
/// default parser.
///
/// @param context Application context.
/// @param parsers Parsers used to open a publication, in addition to the default parsers.
/// @param ignoreDefaultParsers When true, only parsers provided in parsers will be used.
/// @param archiveFactory Opens an archive (e.g. ZIP, RAR), optionally protected by credentials.
/// @param onCreatePublication Called on every parsed [PublicationBuilder]. It can be used to modify
///   the [Manifest], the root [Fetcher] or the list of service factories of a [Publication].
class Streamer {
  final List<StreamPublicationParser> _parsers;
  final bool ignoreDefaultParsers;
  final List<ContentProtection> contentProtections;
  final ArchiveFactory archiveFactory;
  final PdfDocumentFactory pdfFactory;
  final OnCreatePublication onCreatePublication;
  List<StreamPublicationParser> _defaultParsers;

  Streamer(
      {List<StreamPublicationParser> parsers = const [],
      this.ignoreDefaultParsers = false,
      this.contentProtections = const [],
      this.archiveFactory = const DefaultArchiveFactory(),
      this.pdfFactory,
      OnCreatePublication onCreatePublication})
      : _parsers = parsers,
        this.onCreatePublication =
            onCreatePublication ?? _emptyOnCreatePublication;

  /// Parses a [Publication] from the given asset.
  ///
  /// If you are opening the publication to render it in a Navigator, you must set [allowUserInteraction]
  /// to true to prompt the user for its credentials when the publication is protected. However,
  /// set it to false if you just want to import the [Publication] without reading its content, to
  /// avoid prompting the user.
  ///
  /// When using Content Protections, you can use [sender] to provide a free object which can be
  /// used to give some context. For example, it could be the source Activity or Fragment which
  /// would be used to present a credentials dialog.
  ///
  /// The [warnings] logger can be used to observe non-fatal parsing warnings, caused by
  /// publication authoring mistakes. This can be useful to warn users of potential rendering
  /// issues.
  ///
  /// @param asset Digital medium (e.g. a file) used to access the publication.
  /// @param credentials Credentials that Content Protections can use to attempt to unlock a
  ///   publication, for example a password.
  /// @param allowUserInteraction Indicates whether the user can be prompted, for example for its
  ///   credentials.
  /// @param sender Free object that can be used by reading apps to give some UX context when
  ///   presenting dialogs.
  /// @param onCreatePublication Transformation which will be applied on the Publication Builder.
  ///   It can be used to modify the [Manifest], the root [Fetcher] or the list of service
  ///   factories of the [Publication].
  /// @param warnings Logger used to broadcast non-fatal parsing warnings.
  /// @return Null if the asset was not recognized by any parser, or a
  ///   [Publication.OpeningException] in case of failure.
  Future<PublicationTry<Publication>> open(
    PublicationAsset asset,
    bool allowUserInteraction, {
    String credentials,
    dynamic sender,
    OnCreatePublication onCreatePublication,
  }) async {
    onCreatePublication ??= _emptyOnCreatePublication;
    try {
      Fetcher fetcher = (await asset.createFetcher(
              PublicationAssetDependencies(archiveFactory), credentials))
          .getOrThrow();

      Try<ProtectedAsset, OpeningException> protectedAssetResult =
          (await contentProtections.lazyMapFirstNotNullOrNull((it) => it.open(
              asset, fetcher, credentials, allowUserInteraction, sender)));

      if (allowUserInteraction && protectedAssetResult?.isFailure == true) {
        throw protectedAssetResult.failure;
      }

      ProtectedAsset protectedAsset = protectedAssetResult?.getOrNull();
      if (protectedAsset != null) {
        asset = protectedAsset.asset;
        fetcher = protectedAsset.fetcher;
      }

      PublicationBuilder builder =
          (await parsers.lazyMapFirstNotNullOrNull((it) {
        try {
          return it.parseFile(asset, fetcher);
        } on Exception catch (e) {
          throw OpeningException.parsingFailed(e);
        }
      }));
      if (builder == null) {
        throw OpeningException.unsupportedFormat;
      }

      // Transform from the Content Protection.
      protectedAsset?.let((it) => it.onCreatePublication);
      // Transform provided by the reading app during the construction of the Streamer.
      builder.also(this.onCreatePublication);
      // Transform provided by the reading app in `Streamer.open()`.
      builder.also(onCreatePublication);

      Publication publication = builder.also(onCreatePublication).build();

      publication.addLegacyProperties(await asset.mediaType);
      Product2<int, Map<Link, LinkPagination>> infos =
          await PaginationInfosService.computePaginationInfos(publication);
      publication.nbPages = infos.item1;
      publication.paginationInfo = infos.item2;
      // Fimber.d("publication.manifest: ${publication.manifest}");

      return PublicationTry.success(publication);
    } on OpeningException catch (e) {
      return PublicationTry.failure(e);
    }
  }

  List<StreamPublicationParser> get defaultParsers => _defaultParsers ??= [
        EpubParser(),
        PdfParser(pdfFactory),
        ImageParser(),
      ];

  List<StreamPublicationParser> get parsers =>
      List.of(_parsers)..addAll((!ignoreDefaultParsers) ? defaultParsers : []);
}

extension LazyMapFirstNotNullOrNullList<T> on List<T> {
  Future<R> lazyMapFirstNotNullOrNull<R>(
      Future<R> Function(T) transform) async {
    for (T it in this) {
      R result = await transform(it);
      if (result != null) {
        return result;
      }
    }
    return null;
  }
}

extension AddLegacyPropertiesPublication on Publication {
  void addLegacyProperties(MediaType mediaType) {
    type = mediaType.toPublicationType();

    if (mediaType == MediaType.epub) {
      setLayoutStyle();
    }
  }
}

extension ToPublicationTypeMediaType on MediaType {
  TYPE toPublicationType() {
    if ([
      MediaType.readiumAudiobook,
      MediaType.readiumAudiobookManifest,
      MediaType.lcpProtectedAudiobook,
    ].contains(this)) {
      return TYPE.audio;
    }
    if ([
      MediaType.divina,
      MediaType.divinaManifest,
    ].contains(this)) {
      return TYPE.divina;
    }
    if (this == MediaType.cbz) {
      return TYPE.cbz;
    }
    if (this == MediaType.epub) {
      return TYPE.epub;
    }
    return TYPE.webpub;
  }
}

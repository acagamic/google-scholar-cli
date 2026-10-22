import Foundation

// Adapted from @jackwener/opencli 2.0.2, clis/google-scholar/search.js.
// Copyright 2025 jackwener. Modified for standalone use in google-scholar-cli.
func scholarExtractionScript(limit: Int) -> String {
    let itemLimit = min(max(limit, 1), 20)
    return #"""
    (() => {
      const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
      const truncate = (value, maxLength) => Array.from(value).slice(0, maxLength).join('');
      const snapshot = (state, items, resultCount) => ({ state, items, resultCount });
      const hostname = location.hostname.toLowerCase();
      const pathname = location.pathname.toLowerCase();
      const resultCards = Array.from(document.querySelectorAll('.gs_r.gs_or.gs_scl'));

      const challengeMarkup = document.querySelector([
        '#captcha',
        '#captcha-form',
        '.g-recaptcha',
        'form[action*="/sorry/"]',
        'iframe[src*="recaptcha"]',
        'input[name="captcha"]',
      ].join(','));
      const challengeText = resultCards.length === 0
        && /our systems have detected unusual traffic|检测到您的计算机网络中存在异常流量/i.test(
          normalize(document.body?.innerText),
        );
      if (pathname === '/sorry' || pathname.startsWith('/sorry/') || challengeMarkup || challengeText) {
        return JSON.stringify(snapshot('challenge', [], 0));
      }

      const consentHostname = hostname === 'consent.google.com'
        || hostname.endsWith('.consent.google.com');
      const consentForm = document.querySelector([
        'form#consent-form',
        'form[action*="consent.google."]',
        'form[action^="/consent"]',
      ].join(','));
      if (consentHostname || consentForm) {
        return JSON.stringify(snapshot('consent', [], 0));
      }

      const items = [];
      for (const card of resultCards) {
        const container = card.querySelector('.gs_ri') || card;
        const titleRoot = container.querySelector('h3.gs_rt, h3');
        const titleLink = titleRoot?.querySelector('a[href]');
        const title = normalize(titleLink?.textContent || titleRoot?.textContent)
          .replace(/^(?:\[(?:CITATION|BOOK)\]\s*)+/i, '')
          .trim();
        if (!title) {
          continue;
        }

        let url = '';
        const href = titleLink?.getAttribute('href')?.trim();
        if (href) {
          try {
            const parsedURL = new URL(href, location.href);
            if (parsedURL.protocol === 'http:' || parsedURL.protocol === 'https:') {
              url = parsedURL.href;
            }
          } catch {
            url = '';
          }
        }

        const infoLine = normalize(container.querySelector('.gs_a')?.textContent);
        const metadataParts = infoLine.split(/\s+-\s+/);
        const authors = normalize(metadataParts[0]);
        const publication = metadataParts.length > 1 ? normalize(metadataParts[1]) : '';
        const publicationYears = publication.match(/(?:19|20)\d{2}/g) || [];
        const year = publicationYears.length > 0
          ? publicationYears[publicationYears.length - 1]
          : '';
        const trailingYear = publication.match(/(?:^|[\s,;:(])((?:19|20)\d{2})[)\s.,;:]*$/);
        const source = trailingYear
          ? publication.slice(0, trailingYear.index).replace(/[\s,;:(]+$/, '').trim()
          : publication;

        const citedText = normalize(
          container.querySelector('.gs_fl a[href*="cites"]')?.textContent,
        );
        const citedMatch = citedText.match(/[0-9][0-9,\s.]*/);
        const citedDigits = citedMatch ? citedMatch[0].replace(/\D/g, '') : '';

        items.push({
          rank: items.length + 1,
          title,
          authors: truncate(authors, 80),
          source: truncate(source, 60),
          year,
          cited: citedDigits || '0',
          url,
        });

        if (items.length >= \#(itemLimit)) {
          break;
        }
      }

      if (items.length > 0) {
        return JSON.stringify(snapshot('results', items, resultCards.length));
      }

      const emptyElements = Array.from(document.querySelectorAll([
        '#gs_res_ccl_mid .gs_med',
        '#gs_res_ccl_mid .gs_alrt',
      ].join(',')));
      const emptyText = normalize(emptyElements.map((element) => element.textContent).join(' '));
      const emptyEnglish = /did not match any (?:articles|results)|no (?:articles|results) (?:were )?found/i;
      const emptyChinese = /找不到.*(?:学术文章|结果)|未找到.*(?:学术文章|搜索结果|结果)|没有找到.*(?:学术文章|结果)/;

      if (resultCards.length === 0
          && (emptyEnglish.test(emptyText) || emptyChinese.test(emptyText))) {
        return JSON.stringify(snapshot('empty', [], 0));
      }

      return JSON.stringify(snapshot('unknown', [], resultCards.length));
    })()
    """#
}

// Appearance for a selected object with a distinctive print and a second,
// separated region of its base color. Other selections retain the photo route.
// A proposal may advance NanoTrack's search even while this verifier holds.
struct MovingAppearance {
    struct Tile {
        cv::Point origin;
        cv::Mat pixels, ink;
        double rank;
    };
    struct View {
        cv::Mat pixels, ink;
        std::vector<Tile> tiles;
        double base = 0, band = 0, span = 0, brightAnchor = 0;
        int inkCount = 0;
    };
    struct Result {
        CGRect box = CGRectNull;
        double score = 0;
        bool ambiguous = false;
    };
    const char *initializationReason = "not_initialized";
    int initializationColorMarks = 0, initializationHueSupport = 0;
    bool colorPrintReversed = false, weakColorTonalConsensus = false;
    int hue = -1;
    bool reverse = false, horizontal = false, tonal = false;
    double aspect = 0;
    int anchorFloor = 0;
    std::array<bool,18> inkHues{};
    View original, approved, earlierPrint;
    double earlierPrintTime = -INFINITY;
    struct Pending { double time; CGRect rect; View view; };
    CGRect lastVerifiedBox = CGRectNull;
    std::deque<Pending> pending;
    double committedTime = -INFINITY;

    static cv::Rect region(CGRect box, cv::Size size) {
        if (!validRect(box)) return {};
        const int left=cvRound(CGRectGetMinX(box)*size.width), right=cvRound(CGRectGetMaxX(box)*size.width);
        const int top=cvRound((1-CGRectGetMaxY(box))*size.height), bottom=cvRound((1-CGRectGetMinY(box))*size.height);
        return cv::Rect(cv::Point(left,top),cv::Point(right,bottom)) & cv::Rect({},size);
    }

    cv::Mat sample(const cv::Mat &image, cv::Rect rect) const {
        cv::Mat crop=image(rect), upright, normalized;
        if (horizontal) cv::rotate(crop,upright,cv::ROTATE_90_COUNTERCLOCKWISE);
        else upright=crop;
        cv::resize(upright,normalized,{48,96},0,0,cv::INTER_AREA);
        if (reverse) cv::flip(normalized,normalized,0);
        return normalized;
    }

    static int distance(int a, int b) { const int d=std::abs(a-b); return std::min(d,180-d); }

    void masks(const cv::Mat &pixels, cv::Mat &base, cv::Mat &ink, cv::Mat &bins) const {
        cv::Mat hsv;
        cv::cvtColor(pixels,hsv,cv::COLOR_BGR2HSV);
        base=cv::Mat::zeros(hsv.size(),CV_8U); ink=base.clone(); bins=base.clone();
        for (int y=0;y<hsv.rows;++y) for (int x=0;x<hsv.cols;++x) {
            const auto p=hsv.at<cv::Vec3b>(y,x);
            const int d=distance(p[0],hue);
            if (p[1]>=55 && p[2]>=35 && d<=13) base.at<uchar>(y,x)=255;
            if (p[1]>=90 && p[2]>=35 && d>21) ink.at<uchar>(y,x)=255;
            bins.at<uchar>(y,x)=((p[0]+5)%180)/10;
        }
        cv::Mat nearBase;
        if (tonal) {
            // Thin dark text or barcode strokes within the selected base
            // color. Exclude the side boundaries and broad hand/shadow edges.
            cv::Mat gray, strokes, compatible;
            cv::cvtColor(pixels,gray,cv::COLOR_BGR2GRAY);
            cv::morphologyEx(gray,strokes,cv::MORPH_BLACKHAT,cv::Mat::ones(5,5,CV_8U));
            cv::compare(strokes,20,ink,cv::CMP_GE);
            compatible=cv::Mat::zeros(hsv.size(),CV_8U);
            for (int y=0;y<hsv.rows;++y) for (int x=4;x<hsv.cols-4;++x) {
                const auto p=hsv.at<cv::Vec3b>(y,x);
                if (p[1]<80 || distance(p[0],hue)<=18) compatible.at<uchar>(y,x)=255;
            }
            cv::bitwise_and(ink,compatible,ink);
        }
        cv::dilate(base,nearBase,cv::Mat::ones(tonal ? 7 : 5,tonal ? 7 : 5,CV_8U));
        cv::bitwise_and(ink,nearBase,ink);
    }

    View describe(const cv::Mat &pixels) const {
        View view; view.pixels=pixels;
        cv::Mat base,bins;
        masks(pixels,base,view.ink,bins);
        std::vector<int> top,mark;
        for (int y=0;y<pixels.rows;++y) for (int x=0;x<pixels.cols;++x) {
            if (y<43 && base.at<uchar>(y,x)) {
                top.push_back(y);
                const auto bgr=pixels.at<cv::Vec3b>(y,x);
                if (y<28 && std::max({bgr[0],bgr[1],bgr[2]})>=anchorFloor) ++view.brightAnchor;
            }
            if (y>=49 && view.ink.at<uchar>(y,x) && (tonal || inkHues[bins.at<uchar>(y,x)])) mark.push_back(y);
            else view.ink.at<uchar>(y,x)=0;
        }
        view.inkCount=int(mark.size());
        view.base=double(top.size())/(43*pixels.cols);
        view.brightAnchor/=28*pixels.cols;
        view.band=double(cv::countNonZero(base.rowRange(49,96)))/(47*pixels.cols);
        if (top.empty() || mark.empty()) return view;
        view.span=(mark[mark.size()/2]-top[top.size()/2])/96.;
        std::vector<Tile> options;
        for (int y=47;y+17<=96;y+=3) for (int x=1;x<48-17;x+=4) {
            const cv::Rect r(x,y,17,17);
            const int count=cv::countNonZero(view.ink(r));
            if (count<4 || cv::countNonZero(base(r))<.22*r.area()) continue;
            cv::Scalar mean,dev;
            cv::meanStdDev(pixels(r),mean,dev);
            options.push_back({r.tl(),pixels(r),view.ink(r),std::min(42,count)*(12+std::max({dev[0],dev[1],dev[2]}))});
        }
        std::stable_sort(options.begin(),options.end(),[](const Tile &a,const Tile &b){return a.rank>b.rank;});
        for (const auto &tile:options) {
            if (std::any_of(view.tiles.begin(),view.tiles.end(),[&](const Tile &v){return cv::norm(v.origin-tile.origin)<17*.63;})) continue;
            view.tiles.push_back(tile);
            if (view.tiles.size()==4) break;
        }
        return view;
    }

    bool initialize(const cv::Mat &image, CGRect box) {
        const auto rect=region(box,image.size());
        if (rect.width<12 || rect.height<12) { initializationReason="selection_too_small"; return false; }
        aspect=double(rect.width)/rect.height;
        lastVerifiedBox=box;
        horizontal=rect.width>rect.height;
        const auto pixels=sample(image,rect);
        cv::Mat hsv; cv::cvtColor(pixels,hsv,cv::COLOR_BGR2HSV);
        std::array<int,180> histogram{};
        for (const auto &p:cv::Mat_<cv::Vec3b>(hsv)) if (p[1]>=65 && p[2]>=40) ++histogram[p[0]];
        int best=0;
        for (int h=0;h<180;++h) {
            int support=0;
            for (int i=-9;i<=9;++i) support+=histogram[(180+h+i)%180];
            if (support>best) { best=support; hue=h; }
        }
        initializationHueSupport=best;
        if (best<.10*pixels.total()) { initializationReason="insufficient_base_color"; return false; }
        int colorMarks=0;
        for (bool useTone:{false,true}) {
            tonal=useTone;
            cv::Mat base,ink,bins;
            masks(pixels,base,ink,bins);
            reverse=cv::countNonZero(ink.rowRange(0,48))>cv::countNonZero(ink.rowRange(48,96));
            if (!tonal) {
                const cv::Range half=reverse ? cv::Range(0,48) : cv::Range(48,96);
                colorMarks=cv::countNonZero(ink.rowRange(half));
                initializationColorMarks=colorMarks;
                colorPrintReversed=reverse;
                std::array<int,18> counts{};
                for (int y=half.start;y<half.end;++y) for (int x=0;x<ink.cols;++x)
                    if (ink.at<uchar>(y,x)) ++counts[bins.at<uchar>(y,x)];
                for (int i=0;i<18;++i) inkHues[i]=counts[i]+counts[(i+17)%18]+counts[(i+1)%18]>=6;
            }
            const auto reference=sample(image,rect);
            original=View{};
            if (tonal) {
                // Reject a dark monitor or hand behind an isolated barcode.
                // Calibrate to a bright portion of the opposite colored part.
                cv::Mat referenceBase,referenceInk,referenceBins;
                masks(reference,referenceBase,referenceInk,referenceBins);
                std::vector<int> brightness;
                for (int y=0;y<28;++y) for (int x=0;x<reference.cols;++x) if (referenceBase.at<uchar>(y,x)) {
                    const auto p=reference.at<cv::Vec3b>(y,x);
                    brightness.push_back(std::max({p[0],p[1],p[2]}));
                }
                if (brightness.empty()) { initializationReason="missing_bright_anchor"; continue; }
                auto percentile=brightness.begin()+3*brightness.size()/4;
                std::nth_element(brightness.begin(),percentile,brightness.end());
                anchorFloor=std::max(50,cvRound(*percentile*.60));
            }
            original=describe(reference);
            // A weak color fringe may accompany real dark print (including
            // resizing/chroma sampling around lettering). Only corroborate it
            // when both masks locate print at the same end of the selected
            // object. Opposite-end glass/hand edges remain insufficient, and
            // a substantial multicolor design retains the original photo path.
            weakColorTonalConsensus=tonal && colorMarks>std::max(6.,.04*original.inkCount) &&
                colorMarks<.01*pixels.total() && reverse==colorPrintReversed;
            if (tonal && colorMarks>std::max(6.,.04*original.inkCount) && !weakColorTonalConsensus) {
                initializationReason="mixed_color_print"; return false;
            }
            const size_t minTiles=tonal ? 3 : 2;
            const double minInk=tonal ? .025 : .01;
            if (original.base>=.12 && original.band>=.20 && original.inkCount>=minInk*pixels.total() &&
                original.span>=.34 && original.tiles.size()>=minTiles && (!tonal || original.brightAnchor>=.10)) {
                initializationReason="accepted"; return true;
            }
            initializationReason="insufficient_separated_print";
        }
        return false;
    }

    double correspondence(const View &target, const View &reference) const {
        double best=0;
        struct Hit { cv::Point origin, center; double score; };
        std::vector<Hit> hits;
        for (const auto &tile:reference.tiles) for (double scale:{.83,1.,1.20}) {
            const int side=cvRound(17*scale);
            cv::Mat pattern,ink,scores;
            cv::resize(tile.pixels,pattern,{side,side}); cv::resize(tile.ink,ink,{side,side},0,0,cv::INTER_NEAREST);
            cv::matchTemplate(target.pixels.rowRange(40,96),pattern,scores,cv::TM_CCOEFF_NORMED);
            // Several barcode strokes can look alike within one tile. Keep
            // distinct peaks, then require two spatially consistent tiles.
            for (int index=0; index<(tonal ? 3 : 1); ++index) {
                double peak; cv::Point p;
                cv::minMaxLoc(scores,nullptr,&peak,nullptr,&p);
                if (peak<(tonal ? .67 : std::max(.62,best))) break;
                scores(cv::Rect(p.x-3,p.y-3,7,7)&cv::Rect({},scores.size())).setTo(-1);
                p.y+=40;
                if (std::abs(p.x+side*.5-tile.origin.x-8)>22 || std::abs(p.y+side*.5-tile.origin.y-8)>24) continue;
                const cv::Rect at(p,cv::Size(side,side));
                cv::Mat common,delta;
                cv::bitwise_and(ink,target.ink(at),common);
                if (cv::countNonZero(common)<.23*cv::countNonZero(ink)) continue;
                cv::absdiff(target.pixels(at),pattern,delta);
                const auto error=cv::mean(delta,common);
                if ((error[0]+error[1]+error[2])/3>48) continue;
                if (!tonal) { best=std::max(best,peak); continue; }
                const cv::Point center=p+cv::Point(side/2,side/2);
                for (const auto &hit:hits) {
                    const auto deltaPosition=tile.origin-hit.origin;
                    if (cv::norm(deltaPosition)<10 || cv::norm(center-hit.center)<8 ||
                        cv::norm((center-hit.center)-deltaPosition)>12) continue;
                    best=std::max(best,std::sqrt(peak*hit.score));
                }
                hits.push_back({tile.origin,center,peak});
            }
        }
        return best;
    }

    bool supported(const View &view) const {
        return !view.tiles.empty() && (!tonal || view.brightAnchor>=std::max(.065,.12*original.brightAnchor)) &&
            view.base>=std::max(.09,.12*original.base) &&
            view.band>=std::max(.17,.30*original.band) && view.inkCount>=std::max(8.,.16*original.inkCount) &&
            view.span>=.34;
    }

    // An exact necessary condition of supported(), evaluated on the same
    // normalized pixels before allocating ink masks or enumerating print tiles.
    bool supportedColorLayout(const cv::Mat &pixels) const {
        cv::Mat hsv;
        cv::cvtColor(pixels,hsv,cv::COLOR_BGR2HSV);
        int base=0,band=0,bright=0;
        for (int y=0;y<43;++y) {
            const auto row=hsv.ptr<cv::Vec3b>(y);
            for (int x=0;x<hsv.cols;++x) {
                const auto p=row[x];
                if (p[1]>=55 && p[2]>=35 && distance(p[0],hue)<=13) {
                    ++base;
                    if (y<28 && p[2]>=anchorFloor) ++bright;
                }
            }
        }
        if (double(base)/(43*hsv.cols)<std::max(.09,.12*original.base) ||
            (tonal && double(bright)/(28*hsv.cols)<std::max(.065,.12*original.brightAnchor))) return false;
        for (int y=49;y<hsv.rows;++y) {
            const auto row=hsv.ptr<cv::Vec3b>(y);
            for (int x=0;x<hsv.cols;++x) {
                const auto p=row[x];
                band+=p[1]>=55 && p[2]>=35 && distance(p[0],hue)<=13;
            }
        }
        return double(band)/(47*hsv.cols)>=std::max(.17,.30*original.band);
    }

    bool duplicateTonalSurface(const cv::Mat &small, cv::Rect object) const {
        // A narrow strip includes both the colored end and the printed end.
        // Repeated barcode strokes alone cannot disambiguate duplicate copies.
        const int dx=cvRound(object.width*(horizontal ? .10 : .32));
        const int dy=cvRound(object.height*(horizontal ? .32 : .10));
        const cv::Rect band(object.x+dx,object.y+dy,object.width-2*dx,object.height-2*dy);
        if (std::min(band.width,band.height)<5 || (band&cv::Rect({},small.size()))!=band) return false;
        for (double factor:{.68,.83,1.,1.20,1.5}) {
            const cv::Size size(cvRound(band.width*factor),cvRound(band.height*factor));
            if (size.width>small.cols || size.height>small.rows) continue;
            cv::Mat pattern,scores;
            cv::resize(small(band),pattern,size);
            cv::matchTemplate(small,pattern,scores,cv::TM_CCOEFF_NORMED);
            const auto own=cv::Rect(object.x-size.width/2,object.y-size.height/2,object.width+1,object.height+1)&cv::Rect({},scores.size());
            if (!own.empty()) scores(own).setTo(-1);
            double peak; cv::Point p; cv::minMaxLoc(scores,nullptr,&peak,nullptr,&p);
            if (peak<.87) continue;
            cv::Mat delta;
            cv::absdiff(pattern,small(cv::Rect(p,size)),delta);
            const auto error=cv::mean(delta);
            if ((error[0]+error[1]+error[2])/3<26) return true;
        }
        return false;
    }

    mutable const char *duplicateReason = "none";
    mutable double duplicateFixedMS = -1, duplicateCandidateMS = -1;

    bool duplicate(const cv::Mat &image, cv::Rect rect, const View &view) const {
        duplicateReason="none";
        const auto started=cv::getTickCount();
        auto fixedTicks=started-started;
        const double frequency=cv::getTickFrequency(), budget=.040*frequency;
        const auto finish=[&](bool duplicate,const char *reason) {
            duplicateReason=reason;
            duplicateFixedMS=1000.*fixedTicks/frequency;
            duplicateCandidateMS=1000.*std::max(0.,double(cv::getTickCount()-started-fixedTicks))/frequency;
            return duplicate;
        };
        const auto reject=[&](const char *reason) { return finish(true,reason); };
        // The old fixed workload is finite: at most five strip and ten tile
        // correlations. Budget the added peak enumeration and identity checks
        // separately; a busy background still holds if that scan is incomplete.
        // Live results retain the pipeline's 250 ms position freshness guard.
        const auto exhausted=[&] { return cv::getTickCount()-started-fixedTicks>budget; };
        const double scale=std::min(1.,256./std::max(image.cols,image.rows));
        const auto stripStarted=cv::getTickCount();
        cv::Mat small; cv::resize(image,small,{},scale,scale,cv::INTER_AREA);
        const cv::Rect object(cv::Point(rect.tl()*scale),cv::Point(rect.br()*scale));
        const bool competingStrip=tonal && duplicateTonalSurface(small,object);
        fixedTicks+=cv::getTickCount()-stripStarted;
        if (competingStrip) return reject("competing_tonal_strip");
        if (exhausted()) return reject("competitor_budget_exceeded");
        const int side=std::max(6,cvRound(std::min(object.width,object.height)*.39));
        for (size_t i=0;i<std::min(size_t(2),view.tiles.size());++i) {
            const auto p=view.tiles[i].origin;
            const double u=(p.x+8.5)/48, v=reverse ? 1-(p.y+8.5)/96 : (p.y+8.5)/96;
            const int x=cvRound(object.x+object.width*(horizontal ? 1-v : u)-side*.5);
            const int y=cvRound(object.y+object.height*(horizontal ? u : v)-side*.5);
            cv::Rect r(x,y,side,side);
            if ((r & cv::Rect({},small.size()))!=r) continue;
            for (double factor:{.68,.83,1.,1.20,1.5}) {
                const int s=cvRound(side*factor);
                if (s>std::min(small.cols,small.rows)) continue;
                cv::Mat pattern,scores;
                const auto correlationStarted=cv::getTickCount();
                cv::resize(small(r),pattern,{s,s});
                cv::matchTemplate(small,pattern,scores,cv::TM_CCOEFF_NORMED);
                fixedTicks+=cv::getTickCount()-correlationStarted;
                if (exhausted()) return reject("competitor_budget_exceeded");
                const auto own=cv::Rect(object.x-s/2,object.y-s/2,object.width+1,object.height+1)&cv::Rect({},scores.size());
                if (!own.empty()) scores(own).setTo(-1);
                // Extract the same finite above-threshold peaks once. Sorting
                // by score and row-major position preserves minMaxLoc's order;
                // the existing NMS mask still decides which peaks survive.
                std::vector<std::pair<float,int>> peaks;
                for (int y=0;y<scores.rows;++y) {
                    const auto row=scores.ptr<float>(y);
                    for (int x=0;x<scores.cols;++x)
                        if (row[x]>=.87) peaks.emplace_back(row[x],y*scores.cols+x);
                }
                std::sort(peaks.begin(),peaks.end(),[](const auto &a,const auto &b) {
                    return a.first!=b.first ? a.first>b.first : a.second<b.second;
                });
                if (exhausted()) return reject("competitor_budget_exceeded");
                int supportedCandidates=0;
                for (const auto &candidate:peaks) {
                    const double peak=candidate.first;
                    const cv::Point point(candidate.second%scores.cols,candidate.second/scores.cols);
                    if (scores.at<float>(point)<.87) continue;
                    // Each NMS step removes its peak from this finite score
                    // map. A busy background is not itself a second subject;
                    // finish the scan or conservatively hold on the candidate budget.
                    if (exhausted()) return reject("competitor_budget_exceeded");
                    const double w=rect.width*factor, h=rect.height*factor;
                    const int rx=cvRound((point.x+s*.5)/scale-w*(horizontal ? 1-v : u));
                    const int ry=cvRound((point.y+s*.5)/scale-h*(horizontal ? u : v));
                    const cv::Rect rival(rx,ry,cvRound(w),cvRound(h));
                    const auto visible=rival & cv::Rect({},image.size());
                    const double shared=visible.empty() ? 0 : (rect&rival).area();
                    // Equivalent to the photo route's samePhotoLocation:
                    // another print on the current item is not a competitor.
                    const bool sameSubject=shared>0 && shared/(rect.area()+rival.area()-shared)>=.40 &&
                        std::abs((rect.x+.5*rect.width)-(rival.x+.5*rival.width))<.4*std::min(rect.width,rival.width) &&
                        std::abs((rect.y+.5*rect.height)-(rival.y+.5*rival.height))<.4*std::min(rect.height,rival.height);
                    if (!sameSubject && visible==rival) {
                        const auto normalized=sample(image,rival);
                        if (supportedColorLayout(normalized)) {
                            const auto second=describe(normalized);
                            if (supported(second)) {
                                if (supportedCandidates++==6) return reject("competitor_supported_candidates_exceeded");
                                if (correspondence(second,view)>=.72) return reject("competing_print");
                            }
                        }
                    } else if (!sameSubject && peak>=.97 && visible.area()>.45*rival.area()) return reject("partial_competing_print");
                    if (exhausted()) return reject("competitor_budget_exceeded");
                    // A similar print on the desk does not establish a second
                    // complete subject. Examine the remaining competing peaks.
                    scores(cv::Rect(point.x-s/2,point.y-s/2,s+1,s+1)&cv::Rect({},scores.size())).setTo(-1);
                }
            }
        }
        return exhausted() ? reject("competitor_budget_exceeded") : finish(false,"none");
    }


    Result measure(const cv::Mat &image, CGRect proposal, bool searching, double time) {
        duplicateFixedMS=duplicateCandidateMS=-1;
        Result result;
        View selected;
        // The localizer can frame the label tightly enough to clip the other
        // end of the object. Verify small shifts around that same observation.
        // A correction cannot change the network's independent search state.
        const std::array<cv::Point2d,5> offsets={cv::Point2d(),{0,.12},{0,-.12},{.12,0},{-.12,0}};
        const std::array<double,3> scales={1.,.84,1.18};
        for (double scale:scales) {
            // A changed depth makes a barcode too small or too large in the
            // network's box. Search for its original two strokes at that scale.
            if (scale!=1 && (!tonal || !searching || !CGRectIsNull(result.box))) break;
            const CGRect resized=CGRectInset(proposal,proposal.size.width*(1-scale)/2,proposal.size.height*(1-scale)/2);
            for (const auto &offset:offsets) {
                const CGRect candidate=CGRectOffset(resized,offset.x*resized.size.width,offset.y*resized.size.height);
                const auto rect=region(candidate,image.size());
                if (rect.empty()) continue;
                const double ratio=double(rect.width)/rect.height/aspect;
                if (ratio<.63 || ratio>1.70) continue;
                auto current=describe(sample(image,rect));
                if (!supported(current)) continue;
                double score=std::max(correspondence(current,original),correspondence(current,approved));
                if (tonal && searching && score<.78 && !earlierPrint.tiles.empty())
                    score=std::max(score,correspondence(current,earlierPrint));
                if (score<(searching ? .78 : .65) || score<=result.score) continue;
                result.box=candidate;
                result.score=score;
                selected=std::move(current);
                if (offset.x==0 && offset.y==0) break;
            }
        }
        if (CGRectIsNull(result.box)) return result;
        result.ambiguous=duplicate(image,region(result.box,image.size()),selected);
        if (result.ambiguous) {
            result.box=CGRectNull;
            return result;
        }
        pending.push_back({time,result.box,std::move(selected)});
        while (pending.size()>12 || time-pending.front().time>.30) pending.pop_front();
        return result;
    }

    void approve(double time) {
        if (!std::isfinite(time) || time<=committedTime) return;
        for (const auto &p:pending) if (p.time==time) {
            // Keep one alternate print alignment only from a fresh frame
            // that still independently matches the user's immutable selection.
            if (tonal && time-earlierPrintTime>=1 && correspondence(p.view,original)>=.78 &&
                (earlierPrint.tiles.empty() || correspondence(p.view,earlierPrint)<.84)) {
                earlierPrint=p.view;
                earlierPrintTime=time;
            }
            approved=p.view;
            committedTime=time;
            lastVerifiedBox=p.rect;
            break;
        }
    }
};

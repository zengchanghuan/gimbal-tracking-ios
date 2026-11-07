// Included in the photo tracker's anonymous namespace. All coordinates are
// pixels in the same analysis image. Only the explicit selection trains this model.
class CMPhotoMotionLandmarks {
    struct Blob { cv::Rect box; cv::Point2d center; int area; };
    struct Patch { cv::Point center; cv::Mat gray, colorMask; double merit; bool fine; };
    struct TextureHit { const Patch *patch; double score; cv::Point shift; };
    int hue_ = -1;
    Blob anchor_{}, detail_{};
    cv::Rect selection_, subject_;
    cv::Size size_;
    std::vector<Patch> patches_;
    cv::Mat anchorShape_;

    static cv::Mat hueMask(const cv::Mat &hsv, int hue) {
        cv::Mat mask, wrap;
        int lo = hue-11, hi = hue+11;
        cv::inRange(hsv,cv::Scalar(std::max(0,lo),53,39),cv::Scalar(std::min(179,hi),255,255),mask);
        if (lo < 0) cv::inRange(hsv,cv::Scalar(180+lo,53,39),cv::Scalar(179,255,255),wrap);
        if (hi > 179) cv::inRange(hsv,cv::Scalar(0,53,39),cv::Scalar(hi-180,255,255),wrap);
        if (!wrap.empty()) cv::bitwise_or(mask,wrap,mask);
        return mask;
    }

    static std::vector<Blob> blobs(const cv::Mat &mask, cv::Point origin = {}) {
        cv::Mat closed, labels, stats, centers;
        cv::morphologyEx(mask,closed,cv::MORPH_CLOSE,cv::Mat::ones(3,3,CV_8U));
        const int n = cv::connectedComponentsWithStats(closed,labels,stats,centers,8);
        std::vector<Blob> result;
        for (int i=1; i<n; ++i) {
            const int *s=stats.ptr<int>(i);
            if (s[4]<7 || std::min(s[2],s[3])<3) continue;
            result.push_back({{s[0]+origin.x,s[1]+origin.y,s[2],s[3]},
                {centers.at<double>(i,0)+origin.x,centers.at<double>(i,1)+origin.y},s[4]});
        }
        return result;
    }

    static double density(const Blob &b) { return double(b.area)/b.box.area(); }

    void choosePatches(const cv::Mat &gray, const cv::Mat &mask, int radius, bool fine) {
        const int side=2*radius+1, step=std::max(2,radius/2);
        const cv::Rect interior(selection_.x+radius,selection_.y+radius,
                                selection_.width-2*radius,selection_.height-2*radius);
        const cv::Rect area=interior & detail_.box;
        std::vector<Patch> options;
        for (int y=area.y;y<area.br().y;y+=step) for (int x=area.x;x<area.br().x;x+=step) {
            cv::Rect tile(x-radius,y-radius,side,side);
            const cv::Mat color=mask(tile), pattern=gray(tile);
            const double fraction=double(cv::countNonZero(color))/tile.area();
            if (fraction<.45) continue;
            cv::Scalar mean,dev;
            cv::meanStdDev(pattern,mean,dev,color);
            if (dev[0]<8) continue;
            const double edgeWeight=std::min(1.,.5+std::min(x-selection_.x,selection_.br().x-x)/(.28*selection_.width));
            options.push_back({{x,y},pattern,color,std::min(45.,dev[0])*(.60+.4*fraction)*edgeWeight,fine});
        }
        std::stable_sort(options.begin(),options.end(),[](const Patch &a,const Patch &b){return a.merit>b.merit;});
        const size_t first=patches_.size();
        for (const auto &p:options) {
            if (std::any_of(patches_.begin(),patches_.end(),[&](const Patch &old){
                return old.fine==fine && cv::norm(old.center-p.center)<side*.82;
            })) continue;
            patches_.push_back({p.center,p.gray.clone(),p.colorMask.clone(),p.merit,fine});
            if (patches_.size()-first==4) break;
        }
    }

    // A color blob provides only a geometric proposal. Confirm actual printed
    // texture in a different original region, allowing part of it to be covered.
    double textureScore(const cv::Mat &gray, const cv::Mat &mask, const Patch &p, cv::Point &shift) const {
        const auto nominal=p.center-selection_.tl();
        const int rx=cvRound(selection_.width*.37), ry=cvRound(selection_.height*.18);
        const cv::Rect box(nominal.x-p.gray.cols/2-rx,nominal.y-p.gray.rows/2-ry,
                           p.gray.cols+2*rx,p.gray.rows+2*ry);
        const auto search=box & cv::Rect({},gray.size());
        if (search.width<p.gray.cols || search.height<p.gray.rows) return 0;
        cv::Mat response;
        cv::matchTemplate(gray(search),p.gray,response,cv::TM_CCOEFF_NORMED);
        double correlation; cv::Point peak;
        cv::minMaxLoc(response,nullptr,&correlation,nullptr,&peak);
        if (!std::isfinite(correlation) || correlation<.60) return 0;
        const cv::Rect match(peak+search.tl(),p.gray.size());
        shift=match.tl()+cv::Point(p.gray.cols/2,p.gray.rows/2)-nominal;
        const auto maskNow=mask(match), current=gray(match);
        double sx=0,sy=0,sxx=0,syy=0,sxy=0;
        int common=0,count=0;
        for (int y=0;y<p.gray.rows;++y) for (int x=0;x<p.gray.cols;++x) {
            if (!p.colorMask.at<uchar>(y,x)) continue;
            const double a=p.gray.at<uchar>(y,x),b=current.at<uchar>(y,x);
            ++count; common+=maskNow.at<uchar>(y,x)!=0;
            sx+=a;sy+=b;sxx+=a*a;syy+=b*b;sxy+=a*b;
        }
        const double coverage=double(common)/std::max(1,count);
        const double denom=std::sqrt(std::max(0.,count*sxx-sx*sx)*std::max(0.,count*syy-sy*sy));
        if (coverage<.52 || denom<=0 || (count*sxy-sx*sy)/denom<.46) return 0;
        return .72*correlation+.28*coverage;
    }

    double verifyTexture(const cv::Mat &gray,const cv::Mat &mask,double compactness) const {
        std::vector<TextureHit> hits;
        for (const auto &patch:patches_) {
            cv::Point shift;
            const double score=textureScore(gray,mask,patch,shift);
            if (score>0) hits.push_back({&patch,score,shift});
        }
        double best=0; bool independent=false;
        for (const auto &hit:hits) {
            bool corroborated=!hit.patch->fine;
            for (const auto &other:hits) {
                if (other.patch==hit.patch || cv::norm(other.shift-hit.shift)>std::max(3.,.28*selection_.width)) continue;
                const bool separated=cv::norm(other.patch->center-hit.patch->center) >=
                    .8*std::max(other.patch->gray.cols,hit.patch->gray.cols);
                corroborated |= !other.patch->fine || separated;
                independent |= separated;
            }
            if (corroborated) best=std::max(best,hit.score);
        }
        return best>0 ? std::min(1.,.80*best+.20*compactness+(independent?.025:0.)) : 0;
    }

public:
    struct Match { cv::Rect box; double score; };
    enum class Outcome { none, unique, ambiguous, incomplete };
    bool available() const { return !patches_.empty(); }
    CGRect seedRect() const {
        if (!available() || subject_.empty()) return CGRectNull;
        return CGRectMake(double(subject_.x)/size_.width,1.-double(subject_.y+subject_.height)/size_.height,
                          double(subject_.width)/size_.width,double(subject_.height)/size_.height);
    }

    void learn(const cv::Mat &gray,const cv::Mat &hsv,const cv::Rect &selection) {
        if (hsv.empty() || selection.width<16 || selection.height<16 || selection.area()>60000) return;
        size_=gray.size(); selection_=selection;
        const cv::Rect outer=cv::Rect(selection.x-selection.width/2,selection.y-selection.height/2,
            2*selection.width,2*selection.height) & cv::Rect({},size_);
        const int ring=outer.area()-selection.area();
        if (ring<=0) return;
        double best=0;
        for (int hue=0;hue<180;hue+=6) {
            auto surround=hueMask(hsv(outer),hue);
            auto inside=surround(selection-outer.tl());
            const int count=cv::countNonZero(inside);
            const double p=double(count)/selection.area(),q=double(cv::countNonZero(surround)-count)/ring;
            if (p<.045 || p<1.35*(q+.006)) continue;
            auto regions=blobs(inside,selection.tl());
            std::stable_sort(regions.begin(),regions.end(),[](const Blob &a,const Blob &b){return a.area>b.area;});
            const size_t limit=std::min<size_t>(regions.size(),6);
            for (size_t i=0;i<limit;++i) for (size_t j=i+1;j<limit;++j) {
                const auto &large=regions[i],&small=regions[j];
                if (large.area<.012*selection.area() || large.area>.55*selection.area() ||
                    small.area<std::max(9.,.009*selection.area()) || std::min(density(large),density(small))<.42) continue;
                const auto delta=large.center-small.center;
                const double span=std::max(std::abs(delta.x)/selection.width,std::abs(delta.y)/selection.height);
                const auto center=(large.center+small.center)*.5;
                if (span<.36 || std::abs(center.x-(selection.x+.5*selection.width))>.30*selection.width ||
                    std::abs(center.y-(selection.y+.5*selection.height))>.30*selection.height) continue;
                const double rank=span*std::sqrt(double(large.area)*small.area)*std::sqrt(std::min(4.,p/(q+.008)));
                if (rank>best) { best=rank; hue_=hue; anchor_=small; detail_=large; }
            }
        }
        if (hue_<0) return;
        auto mask=hueMask(hsv,hue_);
        const int radius=std::clamp(int(std::min(.28*detail_.box.width,.32*detail_.box.height)),4,13);
        choosePatches(gray,mask,radius,false);
        if (!available()) return;
        if (radius>=8) choosePatches(gray,mask,std::max(4,cvRound(.57*radius)),true);
        cv::resize(mask(anchor_.box),anchorShape_,{12,12},0,0,cv::INTER_NEAREST);
        const auto extent=anchor_.box | detail_.box;
        subject_=selection;
        if (extent.width>=.56*selection.width && extent.height>=.55*selection.height) {
            const int dx=std::max(1,cvRound(extent.width*.08)),dy=std::max(1,cvRound(extent.height*.08));
            subject_=cv::Rect(extent.x-dx,extent.y-dy,extent.width+2*dx,extent.height+2*dy) & selection;
        }
        // A similar neighbor must not establish this new identity at selection.
        Match seed;
        if (find(gray,hsv,seed) != Outcome::unique || !samePhotoLocation(seed.box,subject_)) patches_.clear();
    }

    Outcome find(const cv::Mat &gray,const cv::Mat &hsv,Match &best) const {
        if (!available() || gray.size()!=size_ || hsv.size()!=size_) return Outcome::none;
        const auto start=PhotoClock::now();
        const auto mask=hueMask(hsv,hue_);
        auto regions=blobs(mask);
        std::vector<Match> poses;
        int proposals=0;
        for (const auto &b:regions) {
            if (PhotoClock::now()-start>std::chrono::milliseconds(40)) return Outcome::incomplete;
            const double sw=double(b.box.width)/anchor_.box.width, sh=double(b.box.height)/anchor_.box.height;
            const double areaScale=std::sqrt(sw*sh);
            const double compact=std::min(density(b),density(anchor_))/std::max(density(b),density(anchor_));
            if (areaScale<.48 || areaScale>2.8 || sw/sh<.62 || sw/sh>1.6 || compact<.66) continue;
            cv::Mat shape,common;
            cv::resize(mask(b.box),shape,anchorShape_.size(),0,0,cv::INTER_NEAREST);
            cv::bitwise_and(shape,anchorShape_,common);
            if (2*cv::countNonZero(common)<.66*(cv::countNonZero(shape)+cv::countNonZero(anchorShape_))) continue;
            if (++proposals>24) return Outcome::incomplete;
            Match winner{{},0};
            for (double scale:{sw,areaScale}) for (double angle:{0.,-CV_PI/15,CV_PI/15}) {
                const double a=scale*std::cos(angle),s=scale*std::sin(angle);
                const auto delta=cv::Point2d(selection_.tl())-anchor_.center;
                const cv::Matx23d transform(a,-s,b.center.x+a*delta.x-s*delta.y,s,a,b.center.y+s*delta.x+a*delta.y);
                cv::Mat local,localMask;
                cv::warpAffine(gray,local,transform,selection_.size(),cv::INTER_LINEAR|cv::WARP_INVERSE_MAP);
                cv::warpAffine(mask,localMask,transform,selection_.size(),cv::INTER_NEAREST|cv::WARP_INVERSE_MAP);
                const double score=verifyTexture(local,localMask,compact);
                if (score<=winner.score) continue;
                const cv::Point2d offset=cv::Point2d(subject_.x+.5*subject_.width,subject_.y+.5*subject_.height)-anchor_.center;
                const cv::Point2d center=b.center+cv::Point2d(a*offset.x-s*offset.y,s*offset.x+a*offset.y);
                const cv::Size size(cvRound(subject_.width*scale),cvRound(subject_.height*scale));
                const cv::Rect rect(cvRound(center.x-.5*size.width),cvRound(center.y-.5*size.height),size.width,size.height);
                if (!rect.empty() && (rect & cv::Rect({},size_))==rect) winner={rect,score};
            }
            if (winner.score>0) poses.push_back(winner);
        }
        if (PhotoClock::now()-start>std::chrono::milliseconds(40)) return Outcome::incomplete;
        if (poses.empty()) return Outcome::none;
        best=*std::max_element(poses.begin(),poses.end(),[](const Match &a,const Match &b){return a.score<b.score;});
        if (best.score<.67) return Outcome::none;
        for (const auto &pose:poses)
            if (!samePhotoLocation(best.box,pose.box) && best.score-pose.score<.08) return Outcome::ambiguous;
        return Outcome::unique;
    }
};
